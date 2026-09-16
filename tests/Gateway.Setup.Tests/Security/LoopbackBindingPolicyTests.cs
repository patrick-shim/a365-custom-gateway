using System.Net;
using FluentAssertions;
using Gateway.Setup.Security;
using Microsoft.AspNetCore.Http;

namespace Gateway.Setup.Tests.Security;

public sealed class LoopbackBindingPolicyTests
{
    [Fact]
    public void Listener_UsesIpv4LoopbackAndEphemeralPort()
    {
        var endpoint = LoopbackBindingPolicy.CreateEndpoint();

        endpoint.Address.Should().Be(IPAddress.Loopback);
        endpoint.Port.Should().Be(0);
    }

    [Fact]
    public void RequestBoundary_AllowsOnlyExactIpv4LoopbackHostAndConnection()
    {
        var context = NewContext(IPAddress.Loopback, IPAddress.Loopback, "127.0.0.1:43123");

        LoopbackBindingPolicy.IsAllowedRequest(context).Should().BeTrue();

        LoopbackBindingPolicy.IsAllowedRequest(
            NewContext(IPAddress.Parse("192.0.2.10"), IPAddress.Loopback, "127.0.0.1:43123"))
            .Should().BeFalse();
        LoopbackBindingPolicy.IsAllowedRequest(
            NewContext(IPAddress.Loopback, IPAddress.Loopback, "localhost:43123"))
            .Should().BeFalse();
        LoopbackBindingPolicy.IsAllowedRequest(
            NewContext(IPAddress.Loopback, IPAddress.Any, "127.0.0.1:43123"))
            .Should().BeFalse();
    }

    [Theory]
    [InlineData("GET", "/app.abc123.css", true)]
    [InlineData("GET", "/Gateway.Setup.abc123.styles.css", true)]
    [InlineData("GET", "/_framework/blazor.web.js", true)]
    [InlineData("HEAD", "/_content/Microsoft.FluentUI.AspNetCore.Components/site.css", true)]
    [InlineData("POST", "/_framework/blazor.web.js", false)]
    [InlineData("GET", "/setup/welcome", false)]
    [InlineData("GET", "/_content/Other.Plugin/payload.js", false)]
    public void StaticAssetBoundary_IsReadOnlyAndNarrow(
        string method,
        string path,
        bool expected)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;

        SetupBoundaryMiddleware.IsStaticAssetRequest(context.Request).Should().Be(expected);
    }

    private static DefaultHttpContext NewContext(
        IPAddress remote,
        IPAddress local,
        string host)
    {
        var context = new DefaultHttpContext();
        context.Connection.RemoteIpAddress = remote;
        context.Connection.LocalIpAddress = local;
        context.Request.Host = HostString.FromUriComponent(host);
        return context;
    }
}
