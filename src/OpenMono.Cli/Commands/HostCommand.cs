using OpenMono.Session;
using OpenMono.Utils;

namespace OpenMono.Commands;

/// <summary>
/// Host scope: sandboxed (workspace-only tools) vs whole-machine (HOST_EXEC
/// via the host-bridge). The two modes are different processes, so this
/// command never hot-swaps — it reports state and hands off. The HOST:ON/OFF
/// status-bar chip (AnsiPainter) is the always-visible counterpart.
/// </summary>
public sealed class HostCommand : ICommand
{
    public string Name => "host";
    public string Description => "Show host scope (sandboxed vs whole-machine) and how to switch";
    public CommandType Type => CommandType.Local;

    public Task ExecuteAsync(string[] args, CommandContext context, CancellationToken ct)
    {
        var sub = args.Length > 0 ? args[0].Trim().ToLowerInvariant() : "status";
        var on = context.Session.Meta.HostEnabled;
        switch (sub)
        {
            case "status":
            case "":
                context.Renderer.WriteInfo(on
                    ? "HOST:ON — this session can act on the whole machine via HOST_EXEC (audited, policy-gated)."
                    : "HOST:OFF — sandboxed: workspace-only tools, no host access. Switch with: /host on");
                break;
            case "on":
                if (on)
                    context.Renderer.WriteInfo("HOST:ON already — whole-machine actions go through HOST_EXEC.");
                else
                    context.Renderer.WriteInfo(
                        "Switching to whole-machine mode needs the host-bridge (separate process):\n" +
                        "  1. Exit here (/quit — your sandbox sessions are saved)\n" +
                        "  2. Run: openmono agent --host\n" +
                        "Host scope is per session: this session stays sandboxed.");
                break;
            case "off":
                if (!on)
                    context.Renderer.WriteInfo("HOST:OFF already — sandboxed to the workspace.");
                else
                    context.Renderer.WriteInfo(
                        "To return to sandboxed mode: exit here and run: openmono agent");
                break;
            default:
                context.Renderer.WriteInfo("Usage: /host [status|on|off]");
                break;
        }
        return Task.CompletedTask;
    }
}
