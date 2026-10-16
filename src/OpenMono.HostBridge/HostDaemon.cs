using System.Net;
using System.Text.Json;

namespace OpenMono.HostBridge;

/// <summary>
/// Bare-metal host daemon: the bare-metal half of host mode when the model
/// loop lives in a sandbox container (TUI or ACP/extension), not the operator
/// bridge. It listens on LOOPBACK ONLY and is reached from the container via
/// <c>host.docker.internal</c> (docker-compose sets <c>host-gateway</c>).
///
/// Trust model (defense in depth):
///  - Pairing requires the shared <c>pair_secret</c> (0600 config / env).
///    A random container that lacks it cannot pair. This is a guardrail, not a
///    sandbox boundary.
///  - Pairing mints a random in-memory session token. Every exec must carry it
///    AND the session id it was issued for; a mismatch fails closed. Revoking
///    (client /host off, or daemon stop) drops the token — fail closed again.
///  - The client UI is where the human consents to each command. The daemon
///    does NOT re-consent: it enforces the deny-list (CheckPolicy == Deny) and
///    the sudo policy as its last line of defense. Escalations need
///    <c>allow_sudo=allow</c> (no human at the daemon to answer an "ask").
///  - Every pair/exec/revoke/deny is written to the shared audit trail.
///
/// It reuses the exact execution engine the operator bridge uses
/// (<see cref="HostExecutor"/> + <see cref="HostIdentity"/>), so host policy,
/// sudo, run-as, timeouts, and the paper trail never diverge between surfaces.
/// </summary>
public sealed class HostDaemon : IAsyncDisposable
{
    private readonly HttpListener _listener = new();
    private readonly BridgeConfig _config;
    private readonly HostIdentity _identity;
    private readonly HostExecutor _executor;
    private readonly string _workDir;
    private readonly string _pairSecret;
    private readonly CancellationTokenSource _cts = new();
    private readonly Dictionary<string, SessionLock> _sessions = [];
    private readonly object _sessionsLock = new();
    private readonly TimeSpan _idleTimeout;

    /// <summary>Default idle window after which a session token expires.</summary>
    public static readonly TimeSpan DefaultIdleTimeout = TimeSpan.FromHours(2);

    private sealed record SessionLock(string Token, string WorkDir, DateTime LastSeenUtc);

    public int Port { get; }

    /// <param name="idleTimeout">Idle-token expiry: a pairing whose last seen
    /// activity is older than this dies on the next call (activity refreshes
    /// the clock). <see cref="TimeSpan.Zero"> disables expiry.</see></param>
    public HostDaemon(BridgeConfig config, HostIdentity identity, string workDir, int port, TimeSpan? idleTimeout = null)
    {
        _config = config;
        _identity = identity;
        _executor = new HostExecutor(config.HostExec, workDir, config.ResolvedLogDir, identity);
        _workDir = workDir;
        Port = port;
        _pairSecret = config.PairSecret;
        _idleTimeout = idleTimeout ?? DefaultIdleTimeout;
    }

    /// <summary>
    /// The pairing secret the daemon requires. Empty secret here would let any
    /// process pair, so the caller must have ensured one exists (env or
    /// generated+saved to config) before starting the daemon.
    /// </summary>
    public string PairSecret => _pairSecret;

    public void Start()
    {
        _listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
        _listener.Start();
        _ = AcceptLoopAsync(_cts.Token);
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener.IsListening)
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await _listener.GetContextAsync();
            }
            catch (Exception) when (ct.IsCancellationRequested || !_listener.IsListening)
            {
                return;
            }
            catch (HttpListenerException)
            {
                return;
            }

            _ = HandleSafeAsync(ctx);
        }
    }

    private async Task HandleSafeAsync(HttpListenerContext ctx)
    {
        try
        {
            await HandleAsync(ctx);
        }
        catch (Exception ex)
        {
            AuditLog.WriteNote($"daemon request failed: {ex.Message}");
            try { WriteJson(ctx, 500, new StatusResponse(false, "internal error")); }
            catch { /* client gone */ }
        }
    }

    private async Task HandleAsync(HttpListenerContext ctx)
    {
        var path = ctx.Request.Url?.AbsolutePath ?? "";
        var method = ctx.Request.HttpMethod;

        if (method == "GET" && path == "/ping")
        {
            WriteJson(ctx, 200, new PingResponse(true, true, BridgeOptions.Version));
            return;
        }

        if (method == "GET" && path == "/status")
        {
            // Counts only — never leaks tokens or session ids.
            int paired;
            lock (_sessionsLock)
                paired = _sessions.Count;
            WriteJson(ctx, 200, new DaemonStatusResponse(true, true, Port, BridgeOptions.Version, paired));
            return;
        }

        if (method == "POST" && path == "/pair")
        {
            var req = await ReadJsonAsync<PairRequest>(ctx);
            await HandlePairAsync(ctx, req);
            return;
        }

        if (method == "POST" && path == "/exec")
        {
            var req = await ReadJsonAsync<ExecRequest>(ctx);
            await HandleExecAsync(ctx, req);
            return;
        }

        if (method == "POST" && path == "/revoke")
        {
            var req = await ReadJsonAsync<RevokeRequest>(ctx);
            await HandleRevokeAsync(ctx, req);
            return;
        }

        WriteJson(ctx, 404, new StatusResponse(false, "not found"));
    }

    private async Task HandlePairAsync(HttpListenerContext ctx, PairRequest? req)
    {
        if (req is null)
        {
            WriteJson(ctx, 400, new PairResponse(false, Error: "invalid_json"));
            return;
        }

        // Fail closed: no configured secret means pairing is disabled entirely
        // (the caller is expected to guarantee one exists before Start()).
        if (string.IsNullOrEmpty(_pairSecret) || req.Secret != _pairSecret)
        {
            AuditLog.WriteNote($"pair refused (bad/missing secret) session={LogRedactor.Redact(req.SessionId)}");
            WriteJson(ctx, 403, new PairResponse(false, Error: "bad_secret"));
            return;
        }

        if (string.IsNullOrWhiteSpace(req.SessionId))
        {
            WriteJson(ctx, 400, new PairResponse(false, Error: "missing_session_id"));
            return;
        }

        var token = NewToken();
        lock (_sessionsLock)
        {
            // Re-pair rotates the token: a stale token can never keep working.
            _sessions[req.SessionId] = new SessionLock(token, string.IsNullOrWhiteSpace(req.WorkDir) ? _workDir : req.WorkDir, DateTime.UtcNow);
        }

        AuditLog.WriteNote($"pair ok session={LogRedactor.Redact(req.SessionId)} workdir={req.WorkDir} run_as={_identity.RunAsUser} sudo={_identity.Sudo.ToString().ToLowerInvariant()}");
        WriteJson(ctx, 200, new PairResponse(true, token, _identity.RunAsUser, _identity.Sudo.ToString().ToLowerInvariant(), _config.ResolvedLogDir));
    }

    private async Task HandleExecAsync(HttpListenerContext ctx, ExecRequest? req)
    {
        if (req is null || req.Request is null)
        {
            WriteJson(ctx, 400, new ExecResponse(false, Denied: true, Error: "invalid_json"));
            return;
        }

        // Session lock: token + session id must match a live pairing. Mismatch
        // fails closed — no token, expired token, wrong session = refuse.
        if (!ValidateToken(req.SessionId, req.Token, out var workDir))
        {
            AuditLog.WriteCommand(_identity.RunAsUser, req.Request.AsRoot, req.Request.Command,
                -1, 0, false, "exec refused: no live session token (fail closed)");
            WriteJson(ctx, 403, new ExecResponse(false, Denied: true, Error: "unpaired_or_bad_token"));
            return;
        }

        // Last-line-of-defense policy: the client UI already obtained the user's
        // consent, so here we only enforce the deny-list. CheckPolicy returns
        // Deny only when a deny pattern (or default deny) matches; Ask/Allow are
        // both "the user said yes, run it".
        var decision = _executor.CheckPolicy(req.Request.Command);
        if (decision == HostPolicyDecision.Deny)
        {
            AuditLog.WriteCommand(_identity.RunAsUser, req.Request.AsRoot, req.Request.Command,
                -1, 0, false, "denied by daemon deny-list policy");
            WriteJson(ctx, 200, new ExecResponse(false,
                Output: $"Host execution denied by host-bridge policy (deny-list): {req.Request.Command}",
                Denied: true));
            return;
        }

        // Sudo: there is no human at the daemon to answer an "ask", so any
        // escalation needs an explicit allow_sudo=allow. Ask/Deny → fail closed.
        if (_executor.RequiresElevation(req.Request) && _identity.Sudo != SudoPolicy.Allow)
        {
            AuditLog.WriteCommand(_identity.RunAsUser, req.Request.AsRoot, req.Request.Command,
                -1, 0, false, "sudo refused by daemon (no human at daemon; allow_sudo not allow)");
            WriteJson(ctx, 200, new ExecResponse(false,
                Output: "Host execution denied by host-bridge policy (sudo needs allow_sudo=allow for unattended host mode).",
                Denied: true));
            return;
        }

        // No prompter: a command that blocks on a stdin secret cannot be served
        // unattended; the executor's prompt loop fails fast with guidance.
        var output = await _executor.ExecuteAsync(req.Request, _config.TimeoutMs, _cts.Token, prompter: null);
        var denied = output.StartsWith("ERROR:", StringComparison.Ordinal);
        WriteJson(ctx, 200, new ExecResponse(!denied, output, denied));
    }

    private async Task HandleRevokeAsync(HttpListenerContext ctx, RevokeRequest? req)
    {
        if (req is null || string.IsNullOrWhiteSpace(req.SessionId))
        {
            WriteJson(ctx, 400, new StatusResponse(false, "invalid_json"));
            return;
        }

        bool removed;
        lock (_sessionsLock)
        {
            // Revoke must match the token (a stranger cannot revoke someone
            // else's session), then drops it.
            if (_sessions.TryGetValue(req.SessionId, out var s) && s.Token == req.Token)
            {
                _sessions.Remove(req.SessionId);
                removed = true;
            }
            else
            {
                removed = false;
            }
        }

        AuditLog.WriteNote($"revoke session={LogRedactor.Redact(req.SessionId)} removed={removed}");
        WriteJson(ctx, 200, new StatusResponse(removed, removed ? null : "no_such_session_or_token"));
    }

    private bool ValidateToken(string? sessionId, string? token, out string workDir)
    {
        workDir = _workDir;
        if (string.IsNullOrWhiteSpace(sessionId) || string.IsNullOrWhiteSpace(token))
            return false;
        lock (_sessionsLock)
        {
            if (!_sessions.TryGetValue(sessionId, out var s) || s.Token != token)
                return false;
            // Idle-token expiry: an abandoned pairing dies on its next call
            // (fail closed); any validated call refreshes the clock, so an
            // active session never expires out from under its agent.
            if (_idleTimeout > TimeSpan.Zero &&
                DateTime.UtcNow - s.LastSeenUtc > _idleTimeout)
            {
                _sessions.Remove(sessionId);
                AuditLog.WriteNote($"session token expired after idle session={LogRedactor.Redact(sessionId)}");
                return false;
            }
            _sessions[sessionId] = s with { LastSeenUtc = DateTime.UtcNow };
            workDir = s.WorkDir;
            return true;
        }
    }

    private static string NewToken()
    {
        var bytes = new byte[24];
        System.Security.Cryptography.RandomNumberGenerator.Fill(bytes);
        return Convert.ToHexString(bytes);
    }

    private static async Task<T?> ReadJsonAsync<T>(HttpListenerContext ctx)
    {
        using var reader = new StreamReader(ctx.Request.InputStream);
        var raw = await reader.ReadToEndAsync();
        if (string.IsNullOrWhiteSpace(raw))
            return default;
        try
        {
            return JsonSerializer.Deserialize<T>(raw, BridgeConfig.WebOptions());
        }
        catch (JsonException)
        {
            return default;
        }
    }

    private static void WriteJson<T>(HttpListenerContext ctx, int status, T body)
    {
        var json = JsonSerializer.Serialize(body, BridgeConfig.WebOptions());
        var bytes = System.Text.Encoding.UTF8.GetBytes(json);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.OutputStream.Close();
    }

    public async ValueTask DisposeAsync()
    {
        await _cts.CancelAsync();
        try { _listener.Stop(); } catch { }
        try { _listener.Close(); } catch { }
        lock (_sessionsLock)
            _sessions.Clear();
    }
}
