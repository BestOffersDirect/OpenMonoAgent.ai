using FluentAssertions;
using OpenMono.Session;

namespace OpenMono.Tests.HostBridge;

/// <summary>
/// The daemon-URL rewrite (host.docker.internal -> resolved IPv4) must key on
/// the HOST's OS (OPENMONO_HOST_OS, injected by the launcher), not the
/// container's — the container is always Linux. On a macOS host the literal
/// name must survive: Docker Desktop's vpnkit and Colima's vmnet both route
/// it, and the client's Host-header override matches a bound prefix either
/// way. Rewriting to the vmnet gateway IP (192.168.5.x) is exactly the
/// Colima pairing bug this guards.
/// </summary>
public class HostGatewayBootstrapTests : IDisposable
{
    public void Dispose() => Reset();

    private static void Reset()
    {
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.UrlEnv, null);
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.HostOsEnv, null);
    }

    [Fact]
    public void ResolveBaseUrl_MacHost_KeepsLiteralDockerGatewayName()
    {
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.UrlEnv, "http://host.docker.internal:7476");
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.HostOsEnv, "Darwin");
        HostGatewayBootstrap.ResolveBaseUrl().Should().Be("http://host.docker.internal:7476");
    }

    [Fact]
    public void ResolveBaseUrl_ExplicitPortPreserved_OnMacHost()
    {
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.UrlEnv, "http://host.docker.internal:7999");
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.HostOsEnv, "Darwin");
        HostGatewayBootstrap.ResolveBaseUrl().Should().Be("http://host.docker.internal:7999");
    }

    [Fact]
    public void ResolveBaseUrl_NonGatewayUrl_UsedVerbatim()
    {
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.UrlEnv, "http://192.168.5.2:7476");
        Environment.SetEnvironmentVariable(HostGatewayBootstrap.HostOsEnv, "Darwin");
        HostGatewayBootstrap.ResolveBaseUrl().Should().Be("http://192.168.5.2:7476");
    }
}
