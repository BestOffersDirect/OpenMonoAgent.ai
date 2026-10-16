namespace OpenMono.HostBridge;

/// <summary>
/// One consent vocabulary shared by every surface: the operator bridge's
/// [y]/[a]/[n]/[!] menu, the sandbox TUI choice card, and the ACP extension
/// answer to a HOST EXECUTION question. Maps a free-form answer to a decision
/// plus optional session scope. Unknown answers are never consent.
/// </summary>
public enum HostConsentDecision
{
    AllowOnce,
    AllowAll,
    DenyOnce,
    DenyAll,
}

public static class HostConsent
{
    public static HostConsentDecision Map(string? answer)
    {
        var v = (answer ?? "").Trim().ToLowerInvariant();
        return v switch
        {
            "y" or "yes" or "allow" or "allow once" or "ok" or "run"
                => HostConsentDecision.AllowOnce,
            "a" or "always" or "always allow" or "allow all"
                or "allow all (this session)" or "allow all for session" or "session"
                => HostConsentDecision.AllowAll,
            "n" or "no" or "deny" or "deny once"
                => HostConsentDecision.DenyOnce,
            "!" or "never" or "deny all" or "deny all (stop host mode)"
                => HostConsentDecision.DenyAll,
            _ when HostExecRequest.IsApprove(v) => HostConsentDecision.AllowOnce,
            _ when HostExecRequest.IsDeny(v) => HostConsentDecision.DenyOnce,
            // Anything unrecognized is not consent — a confused answer never
            // runs a host command.
            _ => HostConsentDecision.DenyOnce,
        };
    }
}
