using System.Net;
using Microsoft.AspNetCore.Http;

namespace Gateway.Setup.Security;

internal static class LoopbackBindingPolicy
{
    public static IPEndPoint CreateEndpoint() => new(IPAddress.Loopback, 0);

    public static bool IsAllowedRequest(HttpContext context)
    {
        var remoteAddress = context.Connection.RemoteIpAddress;
        var localAddress = context.Connection.LocalIpAddress;
        var host = context.Request.Host.Host;

        return remoteAddress is not null &&
            localAddress is not null &&
            IPAddress.IsLoopback(remoteAddress) &&
            IPAddress.IsLoopback(localAddress) &&
            string.Equals(host, IPAddress.Loopback.ToString(), StringComparison.Ordinal);
    }
}
