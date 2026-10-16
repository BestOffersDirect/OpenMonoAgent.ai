using OpenMono.HostBridge;

namespace OpenMono.Session;

/// <summary>
/// The sandbox side of host mode: pairs with a bare-metal host-bridge daemon
/// and runs user-approved HOST_EXEC commands on it. The model loop lives in
/// the container and never touches the host directly — every host action is
/// (1) consented by the human in their UI (TUI card / ACP extension answer),
/// then (2) relayed to the daemon, which re-enforces the deny-list + sudo
/// policy as its last line of defense and audits everything.
///
/// Session grants mirror the operator bridge's permission store: once the
/// user answers "allow all", further commands run without re-prompting until
/// the pairing is revoked. Escalations (as_root) always re-prompt — allow-all
/// never covers sudo. The consent vocabulary is shared through
/// <see cref="HostConsent"/> so every surface means the same thing.
/// </summary>
public sealed class HostGateway
{
    private readonly HostDaemonClient _client;
    private readonly string _sessionId;

    private string? _token;
    private bool _allowAll;
    private bool _denyAll;
    private SudoPolicy _sudo = SudoPolicy.Ask;

    public string BaseUrl { get; }
    public string? RunAs { get; private set; }
    public string? HostLogDir { get; private set; }
    public string WorkDir { get; }
    public bool IsPaired => _token is not null;
    public bool SessionAllowsAll => _allowAll;
    public bool SessionDeniesAll => _denyAll;
    public SudoPolicy Sudo => _sudo;
    public string? PairSecret { get; }

    public HostGateway(string baseUrl, string sessionId, string workDir, string? pairSecret = null)
    {
        BaseUrl = baseUrl.TrimEnd('/');
        _client = new HostDaemonClient(BaseUrl);
        _sessionId = sessionId;
        WorkDir = workDir;
        PairSecret = pairSecret;
    }

    /// <summary>
    /// Pair with the daemon using the shared secret. Returns null on success
    /// or a human-readable failure reason. Re-pair rotates the token, so a
    /// second call cleanly replaces a stale pairing.
    /// </summary>
    public async Task<string?> PairAsync(string? secretOverride = null, CancellationToken ct = default)
    {
        var secret = secretOverride ?? PairSecret;
        if (string.IsNullOrWhiteSpace(secret))
            return "no pair secret — set OPENMONO_HOST_PAIR_SECRET (or pair from the host side first: openmono host)";

        var ping = await _client.PingAsync(ct);
        if (!ping.Daemon)
            return $"host daemon not reachable at {BaseUrl} — start it on the host machine: openmono host";

        var resp = await _client.PairAsync(new PairRequest(secret, _sessionId, WorkDir), ct);
        if (!resp.Ok || string.IsNullOrEmpty(resp.Token))
            return resp.Error switch
            {
                "bad_secret" => "pairing was refused (bad pair secret) — check ~/.openmono/host-bridge.json on the host",
                "daemon unreachable" => $"host daemon went down at {BaseUrl}",
                _ => resp.Error ?? "pairing failed",
            };

        _token = resp.Token;
        RunAs = resp.RunAs;
        HostLogDir = resp.LogDir;
        _sudo = resp.Sudo switch
        {
            "allow" => SudoPolicy.Allow,
            "deny" => SudoPolicy.Deny,
            _ => SudoPolicy.Ask,
        };
        _allowAll = false;
        _denyAll = false;
        return null;
    }

    /// <summary>Drop the pairing on the daemon and locally. Idempotent.</summary>
    public async Task UnpairAsync(CancellationToken ct = default)
    {
        if (_token is not null)
        {
            try { await _client.RevokeAsync(new RevokeRequest(_token, _sessionId), ct); }
            catch { /* daemon gone — the token dies with it */ }
        }
        _token = null;
        RunAs = null;
        HostLogDir = null;
        _allowAll = false;
        _denyAll = false;
    }

    /// <summary>
    /// Run one HOST_EXEC request through consent + daemon relay and return the
    /// text answer for the model loop. Never throws on policy/denial — those
    /// come back as textual answers, mirroring the operator bridge exactly.
    /// <paramref name="consent"/> is the surface-specific human prompt.
    /// </summary>
    public async Task<string> RunAsync(
        HostExecRequest request,
        Func<string, bool, CancellationToken, Task<HostConsentDecision>> consent,
        CancellationToken ct)
    {
        if (_token is null)
            return "HOST EXECUTION refused: this session is not paired with a host daemon (/host on).";

        if (request.AsRoot && _sudo == SudoPolicy.Deny)
            return "Host execution refused: as_root was requested but sudo is denied on this host. " +
                "Re-send without \"as_root\": true, or ask the user to enable sudo (openmono config host.sudo_policy allow).";

        var decision = HostConsentDecision.AllowOnce;
        if (_denyAll)
            decision = HostConsentDecision.DenyAll;
        else if (!(_allowAll && !request.AsRoot))
            decision = await consent(request.Command, request.AsRoot, ct);

        switch (decision)
        {
            case HostConsentDecision.AllowAll:
                _allowAll = true;
                break;
            case HostConsentDecision.DenyAll:
                _denyAll = true;
                return $"Host execution denied by user (host mode off for this session): {request.Command}";
            case HostConsentDecision.DenyOnce:
                return $"Host execution denied by user: {request.Command}";
        }

        var resp = await _client.ExecAsync(new ExecRequest(_token, _sessionId, request), ct);
        if (resp.Denied && resp.Error is not null)
        {
            if (resp.Error == "unpaired_or_bad_token")
                return "HOST EXECUTION refused by the host daemon: the session pairing is stale (token rotated or revoked). Re-pair with /host on.";
            return $"Host execution denied by host-bridge policy: {request.Command}";
        }

        var targetUser = request.AsRoot ? "root" : RunAs ?? "host user";
        var head = $"[host-exec on {WorkDir} as {targetUser}]";
        return $"{head}\n$ {request.Command}\n{resp.Output}";
    }

    /// <summary>
    /// The standing-orders preamble for this pairing (null when unpaired).
    /// Injected into the system prompt when host mode activates so the model
    /// knows its own tools see only the container workspace.
    /// </summary>
    public string? BuildStandingOrders() => IsPaired
        ? HostStandingOrders.Build(WorkDir, RunAs ?? "host user", HostLogDir ?? "~/.openmono/logs", _sudo)
        : null;
}
