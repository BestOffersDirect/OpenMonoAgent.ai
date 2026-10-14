using System.Text.Json;

namespace OpenMono.HostBridge;

/// <summary>
/// Drives one ACP session as an operator: sends turns, renders the SSE stream,
/// and resolves pauses. Permission and HOST_EXEC pauses follow local policy;
/// everything else (approvals, free-form input) goes to the operator through
/// the UI (full-screen TUI or plain lines). The model loop and tool execution
/// stay in the container — the only thing that ever runs on bare metal is an
/// approved HOST_EXEC command.
/// </summary>
public sealed class Bridge : IHostExecPrompter
{
    private readonly AcpClient _acp;
    private readonly BridgeConfig _config;
    private readonly HostExecutor _executor;
    private readonly HostIdentity _identity;
    private readonly IBridgeUi _ui;
    private readonly string _workDir;
    private readonly bool _nonInteractive;
    private bool _buildMode;
    // Single session-scoped permission memory: tool grants (base) + host-exec
    // and sudo grants (extension). Replaces _sessionAllow/_sessionDeny.
    private readonly HostExecPermissionStore _store = new();
    // In-container AskUser tool calls carrying a HOST_EXEC envelope have their
    // cards swallowed (the bridge renders that action itself). Pairing is by
    // event order — see HostExecSuppressionTracker. Genuine questions render.
    private readonly HostExecSuppressionTracker _suppression = new();
    // Diagnostic-only pause count (no gate, no cap). Reset per turn.
    private int _pauseCount;
    private string _lastPauseKind = "";

    public Bridge(
        AcpClient acp,
        BridgeConfig config,
        HostExecutor executor,
        HostIdentity identity,
        IBridgeUi ui,
        string workDir,
        bool nonInteractive,
        bool buildMode)
    {
        _acp = acp;
        _config = config;
        _executor = executor;
        _identity = identity;
        _ui = ui;
        _workDir = workDir;
        _nonInteractive = nonInteractive;
        _buildMode = buildMode;
    }

    public async Task<int> RunTurnAsync(string baseUrl, string sessionId, object payload, CancellationToken ct)
    {
        _pauseCount = 0;
        _lastPauseKind = "";
        _suppression.Clear();
        _ui.ResponseBegin();
        try
        {
            return await PumpAsync(baseUrl, sessionId, _acp.PostTurnStreamAsync(baseUrl, sessionId, payload, ct), ct);
        }
        finally
        {
            _ui.ResponseEnd();
        }
    }

    private async Task<int> PumpAsync(
        string baseUrl,
        string sessionId,
        IAsyncEnumerable<AcpEvent> stream,
        CancellationToken ct)
    {
        await foreach (var evt in stream.WithCancellation(ct))
        {
            var code = await HandleEventAsync(baseUrl, sessionId, evt, ct);
            if (code.HasValue)
                return code.Value;
        }
        return 0;
    }

    private void NotePause(string kind)
    {
        // Observability only: never a gate. Long legitimate tasks keep going;
        // a climbing count tells the operator a pause ping-pong may be stuck.
        _pauseCount++;
        _lastPauseKind = kind;
        if (_pauseCount % 25 == 0)
            _ui.Info($"[bridge] {_pauseCount} pauses this turn (no cap — Ctrl-C to abort). Last: {kind}.");
    }

    private async Task<int?> HandleEventAsync(
        string baseUrl, string sessionId, AcpEvent evt, CancellationToken ct)
    {
        switch (evt.Type)
        {
            case "text_delta":
                _ui.Text(Str(evt.Data, "content"));
                return null;
            case "thinking_delta":
                _ui.Thinking(Str(evt.Data, "content"));
                return null;
            case "tool_start":
            {
                var name = Str(evt.Data, "name");
                var id = Str(evt.Data, "id");
                if (name.Equals("AskUser", StringComparison.OrdinalIgnoreCase) && id.Length > 0)
                {
                    // Candidate HOST_EXEC carrier: hold the card until its
                    // user_input_request classifies it (exact, no text parsing).
                    _suppression.TrackAskUserStart(id);
                    return null;
                }
                _ui.ToolStart(name, Str(evt.Data, "summary"));
                return null;
            }
            case "tool_end":
            {
                var id = Str(evt.Data, "id");
                if (_suppression.ConsumeIfSuppressed(id))
                    return null;
                var ok = evt.Data.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
                var reason = Str(evt.Data, "reason");
                _ui.ToolEnd(Str(evt.Data, "name"), ok, reason);
                return null;
            }
            case "usage":
            {
                // The server emits snake_case (context_tokens/context_window);
                // accept camelCase too in case the wire format ever changes.
                _ui.Usage(NumAny(evt.Data, "context_tokens", "contextTokens"), NumAny(evt.Data, "context_window", "contextWindow"));
                return null;
            }
            case "sub_agent_log":
            {
                var line = Str(evt.Data, "line");
                if (line.Length > 0)
                    _ui.Thinking(line.EndsWith('\n') ? line : line + "\n");
                return null;
            }
            case "permission_request":
            {
                NotePause("permission_request");
                var allow = await ResolveToolPermissionAsync(
                    Str(evt.Data, "tool"), Str(evt.Data, "summary"), IsDangerous(evt.Data), ct);
                return await PumpAsync(baseUrl, sessionId,
                    _acp.PostTurnStreamAsync(baseUrl, sessionId,
                        AcpClient.PermissionPayload(Str(evt.Data, "id"), allow, _config.PermissionScope), ct),
                    ct);
            }
            case "user_input_request":
                NotePause("user_input_request");
                return await ResolveUserInputAsync(baseUrl, sessionId, evt, ct);
            case "playbook_permission_request":
            {
                NotePause("playbook_permission_request");
                var id = Str(evt.Data, "id");
                var name = Str(evt.Data, "playbookName");
                var allow = await _ui.PlaybookAsync(
                    name, ParseSteps(evt.Data), ParseTools(evt.Data),
                    evt.Data.TryGetProperty("requiresModeSwitch", out var rmEl) && rmEl.ValueKind == JsonValueKind.True,
                    ct);
                _ui.PlaybookDecision(name, allow);
                return await PumpAsync(baseUrl, sessionId,
                    _acp.PostTurnStreamAsync(baseUrl, sessionId,
                        AcpClient.PlaybookPayload(id, allow), ct),
                    ct);
            }
            case "toggle_mode_request":
            {
                NotePause("toggle_mode_request");
                var id = Str(evt.Data, "id");
                // The agent only ever asks to go build. If we already put the
                // session there, approve without bothering the operator.
                var approve = _buildMode ||
                    await _ui.ConfirmAsync($"Agent requests build mode ({Str(evt.Data, "reason")}). Approve?", ct);
                if (_buildMode)
                    _ui.Info("[bridge] already in build mode — approving the switch.");
                return await PumpAsync(baseUrl, sessionId,
                    _acp.PostTurnStreamAsync(baseUrl, sessionId,
                        AcpClient.ToggleModePayload(id, approve), ct),
                    ct);
            }
            case "mode_changed":
            {
                var mode = Str(evt.Data, "mode");
                _buildMode = !mode.Equals("plan", StringComparison.OrdinalIgnoreCase);
                _ui.ModeNotice(mode);
                return null;
            }
            case "plan_ready":
            {
                var plan = Str(evt.Data, "plan");
                if (plan.Length > 0)
                    _ui.Markdown(plan);
                _ui.Info("[plan] ready — reply with your decision (or use the prompt).");
                return null;
            }
            case "escalated":
                _ui.Error($"\n[bridge] turn escalated ({Str(evt.Data, "kind")}). It needs your direction.");
                return 2;
            case "done":
                return 0;
            case "error":
                _ui.Error($"\n[bridge] turn error: {Str(evt.Data, "message")}");
                return 1;
            default:
                return null;
        }
    }

    private async Task<int> ResolveUserInputAsync(
        string baseUrl, string sessionId, AcpEvent evt, CancellationToken ct)
    {
        var id = Str(evt.Data, "id");
        var question = Str(evt.Data, "question");

        // Pair with the AskUser tool call that produced this prompt (FIFO —
        // prompts arrive in start order). The tracker marks the linked call
        // suppressed when this is a HOST_EXEC carrier. HOST_EXEC executes
        // regardless of linkage (playbook param prompts have no AskUser
        // origin); genuine questions render their deferred card with full text.
        var isHostExec = HostExecRequest.LooksLikeHostExec(question);
        var linkedToolId = _suppression.LinkPrompt(isHostExec);

        if (isHostExec)
        {
            string answer;
            if (HostExecRequest.TryParse(question, out var request) && request is not null)
            {
                answer = await RunHostExecAsync(request, ct);
            }
            else
            {
                // Malformed envelope (e.g. an 8 KB heredoc the model failed to
                // JSON-escape). Never park the operator in front of raw JSON:
                // audit it and answer the agent with how to re-send, so the
                // turn resumes instead of stalling on PENDING_RESPONSE.
                answer = MalformedEnvelopeAnswer(question);
                AuditLog.WriteCommand(_identity.RunAsUser, false, Truncate(question, 500),
                    -1, 0, false, "HOST_EXEC envelope unparseable; auto-replied, operator not asked");
                _ui.Info("[bridge] HOST_EXEC envelope unparseable — asked the agent to re-send it.");
            }
            return await PumpAsync(baseUrl, sessionId,
                _acp.PostTurnStreamAsync(baseUrl, sessionId,
                    AcpClient.UserInputPayload(id, answer), ct),
                ct);
        }

        // Genuine question: render the deferred AskUser card (if it had an
        // AskUser origin), then prompt with the full text.
        if (!isHostExec && linkedToolId is not null)
            _ui.ToolStart("AskUser", question);

        if (_nonInteractive)
        {
            _ui.Error($"\n[bridge] input requested but --non-interactive is set: {Truncate(question, 300)}");
            return 2;
        }
        var answerText = await _ui.InputAsync(question, ct);
        return await PumpAsync(baseUrl, sessionId,
            _acp.PostTurnStreamAsync(baseUrl, sessionId,
                AcpClient.UserInputPayload(id, answerText), ct),
            ct);
    }

    /// <summary>
    /// The turn-resuming answer for a HOST_EXEC envelope that claims the
    /// prefix but does not parse. Tells the agent exactly how to re-send
    /// (valid JSON with \n escapes, or raw shell, or smaller chunks) instead
    /// of parking the operator in front of a raw JSON blob forever.
    /// </summary>
    public static string MalformedEnvelopeAnswer(string question) =>
        $"HOST_EXEC envelope rejected ({question.Length} chars): it starts with HOST_EXEC: but is not " +
        "a raw shell command and not valid envelope JSON, so nothing ran. Re-send ONE of these shapes: " +
        "(1) HOST_EXEC: {\"command\": \"<shell>\", \"timeout_ms\": 30000} with real JSON inside — escape every " +
        "newline as \\n and every quote as \\\"; " +
        "(2) HOST_EXEC: <raw shell command> with no JSON at all (heredocs welcome); " +
        "(3) split payloads over ~4 KB into several HOST_EXEC calls appending with cat >>. " +
        "Never ask the operator to hand-edit JSON.";

    private async Task<string> RunHostExecAsync(HostExecRequest request, CancellationToken ct)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        var decision = _executor.CheckPolicy(request.Command);
        var targetUser = request.AsRoot ? "root" : _identity.RunAsUser;

        // Sudo escalation check (allow_sudo policy). The executor's sudo gate
        // refuses Deny; Allow passes; Ask confirms here, per command, through
        // the same 4-option permission menu the regular agent uses
        // ([y] Allow / [a] Allow all / [n] Deny / [!] Deny all). A once-answer
        // is in-memory only for THIS command — config stays ask until the
        // operator explicitly changes it (openmono config host.sudo_policy).
        if (_executor.RequiresElevation(request) && _identity.Sudo == SudoPolicy.Ask)
        {
            if (_store.TryResolveSudo() is { Allow: false })
            {
                AuditLog.WriteCommand(targetUser, request.AsRoot, request.Command,
                    -1, stopwatch.ElapsedMilliseconds, false,
                    "sudo ask policy denied for session (deny all)");
                return $"Host execution denied by operator (sudo denied for session): {request.Command}";
            }
            if (_store.TryResolveSudo() is not { Allow: true })
            {
                var interactive = !_nonInteractive && !Console.IsInputRedirected;
                if (!interactive)
                {
                    // Non-interactive fail closed: an ask policy can never
                    // escalate without a human at the keyboard.
                    AuditLog.WriteCommand(targetUser, request.AsRoot, request.Command,
                        -1, stopwatch.ElapsedMilliseconds, false,
                        "sudo ask policy in a non-interactive bridge (fail closed)");
                    return "Host execution denied by bridge policy (sudo ask policy, non-interactive): " + request.Command;
                }
                var (allow, scope) = await _ui.PermissionAsync(
                    "sudo", $"Run '{request.Command}' as {targetUser} with sudo?", ct);
                if (scope == "session")
                    _store.RememberSudo(allow, OpenMono.Permissions.GrantScope.Session);
                if (!allow)
                {
                    AuditLog.WriteCommand(targetUser, request.AsRoot, request.Command,
                        -1, stopwatch.ElapsedMilliseconds, false, "operator declined sudo ask");
                    return $"Host execution denied by operator (sudo ask policy): {request.Command}";
                }
            }
        }

        if (decision == HostPolicyDecision.Ask && !_nonInteractive)
        {
            if (_store.TryResolveHostExec() is { Allow: false })
            {
                decision = HostPolicyDecision.Deny;
            }
            else if (_store.TryResolveHostExec() is { Allow: true })
            {
                decision = HostPolicyDecision.Allow;
            }
            else
            {
                var (allow, scope) = await _ui.PermissionAsync("host-exec", request.Command, ct);
                if (scope == "session")
                    _store.RememberHostExec(allow, OpenMono.Permissions.GrantScope.Session);
                decision = allow ? HostPolicyDecision.Allow : HostPolicyDecision.Deny;
            }
        }
        if (decision != HostPolicyDecision.Allow)
        {
            var denial = decision == HostPolicyDecision.Ask
                ? "non-interactive bridge denied an ask-policy command"
                : "denied by bridge policy";
            AuditLog.WriteCommand(targetUser, request.AsRoot, request.Command,
                -1, stopwatch.ElapsedMilliseconds, false, denial);
            return $"Host execution denied by bridge policy{(decision == HostPolicyDecision.Ask ? " (non-interactive)" : "")}: {request.Command}";
        }

        // Lazy password: only when this exact escalation needs one we do not
        // have. Masked prompt, memory-only, never logged. The TUI briefly
        // stands down fullscreen so the secret never touches its input box.
        if (_executor.NeedsPassword(request))
        {
            if (_nonInteractive || Console.IsInputRedirected)
                return $"ERROR: elevation to '{targetUser}' needs a sudo password and none is in memory. " +
                    "Restart interactively to provide it, or set OPENMONO_HOST_PASSWORD_FILE.";
            _ui.Info($"[host] elevation to '{targetUser}' needs the sudo password.");
            _identity.SetPassword(await _ui.PasswordAsync($"Sudo password for '{targetUser}' (type it — nothing is logged): ", ct));
        }

        // Pre-exec hint only (never blocking): warn about TTY-direct secrets
        // up front so the operator is not surprised by the guidance error.
        switch (HostExecInteraction.Classify(request.Command))
        {
            case InteractiveHint.StdinSecret:
            case InteractiveHint.StdinConfirm:
                _ui.Info("[host] this command may ask for input — you'll be prompted if it does.");
                break;
            case InteractiveHint.TtySecret:
                _ui.Info("[host] note: ssh-style password prompts need a TTY — prefer key auth.");
                break;
            default:
                break;
        }

        _ui.HostStart(request.Command);
        var output = await _executor.ExecuteAsync(request, _config.TimeoutMs, ct, this);
        _ui.HostDone(request.Command, output);
        return $"[host-exec on {_workDir}]\n$ {request.Command}\n{output}";
    }

    // IHostExecPrompter: commands that block on stdin ask the operator through
    // the existing UI. Answers are per-command, never session grants, and
    // secrets are never logged (only the prompt excerpt + channel are audited).
    bool IHostExecPrompter.CanPrompt => !_nonInteractive && !Console.IsInputRedirected;

    async Task<char[]?> IHostExecPrompter.AskSecretAsync(string promptExcerpt, CancellationToken ct)
    {
        AuditPrompt(promptExcerpt, "masked");
        try
        {
            return await _ui.PasswordAsync($"[host] input needed ({promptExcerpt}): ", ct);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    async Task<string?> IHostExecPrompter.AskTextAsync(string promptExcerpt, CancellationToken ct)
    {
        AuditPrompt(promptExcerpt, "echoed");
        try
        {
            return await _ui.InputAsync($"[host] input needed ({promptExcerpt}) ", ct);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    async Task<bool?> IHostExecPrompter.AskConfirmAsync(string promptExcerpt, CancellationToken ct)
    {
        AuditPrompt(promptExcerpt, "confirm");
        try
        {
            return await _ui.ConfirmAsync($"[host] {promptExcerpt} ", ct);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    private void AuditPrompt(string excerpt, string channel) =>
        AuditLog.WriteCommand(_identity.RunAsUser, false,
            excerpt.Length > 200 ? excerpt[..200] + "..." : excerpt,
            -1, 0, false, $"host stdin prompt shown ({channel}); value never logged");

    private async Task<bool> ResolveToolPermissionAsync(string tool, string summary, bool dangerous, CancellationToken ct)
    {
        _config.Tools.TryGetValue(tool, out var rule);
        rule = (rule ?? _config.ToolDefault).Trim().ToLowerInvariant();
        var explicitAllow = _config.Tools.ContainsKey(tool) && rule == "allow";
        // Session memory first (full text to the UI — wrap, never truncate).
        if (_store.TryResolve(tool) is { Allow: false })
        {
            _ui.Info($"[bridge] session-deny {tool} ({summary})");
            return false;
        }
        if (_store.TryResolve(tool) is { Allow: true })
        {
            _ui.Info($"[bridge] session-allow {tool} ({summary}) [{_config.PermissionScope}]");
            return true;
        }
        if (dangerous && !explicitAllow)
        {
            _ui.Info($"[bridge] dangerous {tool} ({summary}) — asking operator.");
            var (allow, scope) = await _ui.PermissionAsync(tool, $"Allow dangerous {tool}? {summary}", ct);
            if (scope == "session")
                _store.Remember(tool, allow, OpenMono.Permissions.GrantScope.Session);
            return allow;
        }
        if (rule == "allow")
        {
            _ui.Info($"[bridge] auto-allow {tool} ({summary}) [{_config.PermissionScope}]");
            return true;
        }
        if (rule == "deny")
        {
            _ui.Info($"[bridge] auto-deny {tool} ({summary})");
            return false;
        }
        var (ok, okScope) = await _ui.PermissionAsync(tool, $"Allow {tool}? {summary}", ct);
        if (okScope == "session")
            _store.Remember(tool, ok, OpenMono.Permissions.GrantScope.Session);
        return ok;
    }

    private static List<PlaybookStep> ParseSteps(JsonElement data)
    {
        var steps = new List<PlaybookStep>();
        if (data.ValueKind == JsonValueKind.Object &&
            data.TryGetProperty("steps", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var el in arr.EnumerateArray())
            {
                if (el.ValueKind != JsonValueKind.Object)
                    continue;
                steps.Add(new PlaybookStep(Str(el, "id"), Str(el, "gate"), Str(el, "description")));
            }
        }
        return steps;
    }

    private static List<PlaybookTool> ParseTools(JsonElement data)
    {
        var tools = new List<PlaybookTool>();
        if (data.ValueKind == JsonValueKind.Object &&
            data.TryGetProperty("tools", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var el in arr.EnumerateArray())
            {
                if (el.ValueKind != JsonValueKind.Object)
                    continue;
                tools.Add(new PlaybookTool(
                    Str(el, "name"),
                    el.TryGetProperty("isReadOnly", out var ro) && ro.ValueKind == JsonValueKind.True,
                    el.TryGetProperty("dangerous", out var dg) && dg.ValueKind == JsonValueKind.True));
            }
        }
        return tools;
    }

    private static bool IsDangerous(JsonElement data) =>
        data.TryGetProperty("dangerous", out var el) && el.ValueKind == JsonValueKind.True;

    private static string Str(JsonElement data, string name) =>
        data.ValueKind == JsonValueKind.Object &&
        data.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String
            ? el.GetString() ?? ""
            : "";

    private static long Num(JsonElement data, string name) =>
        data.ValueKind == JsonValueKind.Object &&
        data.TryGetProperty(name, out var el) && el.TryGetInt64(out var v)
            ? v
            : 0;

    /// <summary>
    /// First positive value wins: prefers the server's snake_case usage field,
    /// falls back to camelCase. A missing field reads 0 either way.
    /// </summary>
    private static long NumAny(JsonElement data, string first, string second)
    {
        var v = Num(data, first);
        return v > 0 ? v : Num(data, second);
    }

    private static string Truncate(string s, int max) =>
        string.IsNullOrEmpty(s) || s.Length <= max ? s ?? "" : s[..max] + "...";
}
