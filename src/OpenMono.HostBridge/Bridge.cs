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
public sealed class Bridge
{
    private const int MaxPauseDepth = 25;

    private readonly AcpClient _acp;
    private readonly BridgeConfig _config;
    private readonly HostExecutor _executor;
    private readonly HostIdentity _identity;
    private readonly IBridgeUi _ui;
    private readonly string _workDir;
    private readonly bool _nonInteractive;
    private bool _buildMode;
    // Session-scoped answers from the permission menu ("allow all" / "deny
    // all"): in-memory only, mirroring the regular agent's PermissionEngine.
    // Keyed by tool name ("sudo", "host-exec", or the ACP tool name).
    private readonly HashSet<string> _sessionAllow = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _sessionDeny = new(StringComparer.OrdinalIgnoreCase);
    // In-container AskUser call ids whose tool cards are swallowed because
    // they carry a HOST_EXEC envelope (the bridge renders that action itself).
    private readonly HashSet<string> _suppressedToolCalls = new(StringComparer.Ordinal);

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
        _ui.ResponseBegin();
        try
        {
            return await PumpAsync(baseUrl, sessionId, _acp.PostTurnStreamAsync(baseUrl, sessionId, payload, ct), 0, ct);
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
        int depth,
        CancellationToken ct)
    {
        if (depth > MaxPauseDepth)
        {
            _ui.Error("[bridge] ERROR: pause nesting too deep — aborting turn.");
            return 1;
        }

        await foreach (var evt in stream.WithCancellation(ct))
        {
            var code = await HandleEventAsync(baseUrl, sessionId, evt, depth, ct);
            if (code.HasValue)
                return code.Value;
        }
        return 0;
    }

    private async Task<int?> HandleEventAsync(
        string baseUrl, string sessionId, AcpEvent evt, int depth, CancellationToken ct)
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
                var suppressId = HostExecSuppressionId(name, evt.Data);
                if (suppressId is not null)
                {
                    // The in-container AskUser call carrying a HOST_EXEC
                    // envelope: the bridge renders its own host-exec card +
                    // prompt for the same action, so the raw-JSON card would be
                    // a duplicate. Swallow it (and its tool_end, correlated
                    // below by call id).
                    if (_suppressedToolCalls.Count > 64)
                        _suppressedToolCalls.Clear();
                    _suppressedToolCalls.Add(suppressId);
                    return null;
                }
                _ui.ToolStart(name, Str(evt.Data, "summary"));
                return null;
            }
            case "tool_end":
            {
                var id = Str(evt.Data, "id");
                if (id.Length > 0 && _suppressedToolCalls.Remove(id))
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
                var allow = await ResolveToolPermissionAsync(
                    Str(evt.Data, "tool"), Str(evt.Data, "summary"), IsDangerous(evt.Data), ct);
                return await PumpAsync(baseUrl, sessionId,
                    _acp.PostTurnStreamAsync(baseUrl, sessionId,
                        AcpClient.PermissionPayload(Str(evt.Data, "id"), allow, _config.PermissionScope), ct),
                    depth + 1, ct);
            }
            case "user_input_request":
                return await ResolveUserInputAsync(baseUrl, sessionId, evt, depth, ct);
            case "playbook_permission_request":
            {
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
                    depth + 1, ct);
            }
            case "toggle_mode_request":
            {
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
                    depth + 1, ct);
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
        string baseUrl, string sessionId, AcpEvent evt, int depth, CancellationToken ct)
    {
        var id = Str(evt.Data, "id");
        var question = Str(evt.Data, "question");

        if (HostExecRequest.LooksLikeHostExec(question))
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
                depth + 1, ct);
        }

        if (_nonInteractive)
        {
            _ui.Error($"\n[bridge] input requested but --non-interactive is set: {Truncate(question, 300)}");
            return 2;
        }
        var answerText = await _ui.InputAsync(question, ct);
        return await PumpAsync(baseUrl, sessionId,
            _acp.PostTurnStreamAsync(baseUrl, sessionId,
                AcpClient.UserInputPayload(id, answerText), ct),
            depth + 1, ct);
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
            if (_sessionDeny.Contains("sudo"))
            {
                AuditLog.WriteCommand(targetUser, request.AsRoot, request.Command,
                    -1, stopwatch.ElapsedMilliseconds, false,
                    "sudo ask policy denied for session (deny all)");
                return $"Host execution denied by operator (sudo denied for session): {request.Command}";
            }
            if (!_sessionAllow.Contains("sudo"))
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
                    "sudo", $"Run '{Truncate(request.Command, 200)}' as {targetUser} with sudo?", ct);
                if (scope == "session")
                {
                    if (allow) _sessionAllow.Add("sudo");
                    else _sessionDeny.Add("sudo");
                }
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
            if (_sessionDeny.Contains("host-exec"))
            {
                decision = HostPolicyDecision.Deny;
            }
            else if (_sessionAllow.Contains("host-exec"))
            {
                decision = HostPolicyDecision.Allow;
            }
            else
            {
                var (allow, scope) = await _ui.PermissionAsync("host-exec", request.Command, ct);
                if (scope == "session")
                {
                    if (allow) _sessionAllow.Add("host-exec");
                    else _sessionDeny.Add("host-exec");
                }
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

        _ui.HostStart(request.Command);
        var output = await _executor.ExecuteAsync(request, _config.TimeoutMs, ct);
        _ui.HostDone(request.Command, output);
        return $"[host-exec on {_workDir}]\n$ {request.Command}\n{output}";
    }

    private async Task<bool> ResolveToolPermissionAsync(string tool, string summary, bool dangerous, CancellationToken ct)
    {
        _config.Tools.TryGetValue(tool, out var rule);
        rule = (rule ?? _config.ToolDefault).Trim().ToLowerInvariant();
        var explicitAllow = _config.Tools.ContainsKey(tool) && rule == "allow";
        if (_sessionDeny.Contains(tool))
        {
            _ui.Info($"[bridge] session-deny {tool} ({Truncate(summary, 120)})");
            return false;
        }
        if (_sessionAllow.Contains(tool))
        {
            _ui.Info($"[bridge] session-allow {tool} ({Truncate(summary, 120)}) [{_config.PermissionScope}]");
            return true;
        }
        if (dangerous && !explicitAllow)
        {
            _ui.Info($"[bridge] dangerous {tool} ({Truncate(summary, 120)}) — asking operator.");
            var (allow, scope) = await _ui.PermissionAsync(tool, $"Allow dangerous {tool}? {Truncate(summary, 200)}", ct);
            if (scope == "session")
            {
                if (allow) _sessionAllow.Add(tool);
                else _sessionDeny.Add(tool);
            }
            return allow;
        }
        if (rule == "allow")
        {
            _ui.Info($"[bridge] auto-allow {tool} ({Truncate(summary, 120)}) [{_config.PermissionScope}]");
            return true;
        }
        if (rule == "deny")
        {
            _ui.Info($"[bridge] auto-deny {tool} ({Truncate(summary, 120)})");
            return false;
        }
        var (ok, okScope) = await _ui.PermissionAsync(tool, $"Allow {tool}? {Truncate(summary, 200)}", ct);
        if (okScope == "session")
        {
            if (ok) _sessionAllow.Add(tool);
            else _sessionDeny.Add(tool);
        }
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

    /// <summary>
    /// The call id to suppress when this tool_start is the in-container
    /// AskUser call carrying a HOST_EXEC envelope (its summary is the raw
    /// AskUser args JSON, e.g. <c>{"question":"HOST_EXEC: ..."}</c>), else
    /// null. Genuine AskUser questions are never suppressed.
    /// </summary>
    private static string? HostExecSuppressionId(string name, JsonElement data)
    {
        if (!name.Equals("AskUser", StringComparison.OrdinalIgnoreCase))
            return null;
        var id = Str(data, "id");
        if (id.Length == 0)
            return null;
        if (HostExecRequest.LooksLikeHostExec(Str(data, "summary")))
            return id;
        if (data.TryGetProperty("arguments", out var argsEl) &&
            argsEl.ValueKind == JsonValueKind.String &&
            LooksLikeHostExecArgs(argsEl.GetString()))
            return id;
        return null;
    }

    private static bool LooksLikeHostExecArgs(string? args)
    {
        if (string.IsNullOrWhiteSpace(args))
            return false;
        try
        {
            using var doc = JsonDocument.Parse(args);
            if (doc.RootElement.TryGetProperty("question", out var q) &&
                q.ValueKind == JsonValueKind.String &&
                HostExecRequest.LooksLikeHostExec(q.GetString() ?? ""))
                return true;
        }
        catch (JsonException)
        {
        }
        return args.Contains(HostExecRequest.Prefix, StringComparison.Ordinal);
    }

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
