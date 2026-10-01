using Gateway.Api.Options;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Options;
using IPNetwork = System.Net.IPNetwork;

namespace Gateway.Api.Infrastructure;

public static class GatewayIngressServiceCollectionExtensions
{
    public static IServiceCollection AddGatewayIngress(
        this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<GatewayIngressOptions>()
            .Bind(configuration.GetSection(GatewayIngressOptions.SectionName))
            .Validate(GatewayIngressOptions.IsValid,
                "GatewayIngress:TrustedProxyNetworks must contain at most eight distinct canonical CIDRs; trust-all networks are forbidden.")
            .ValidateOnStart();
        services.AddOptions<ForwardedHeadersOptions>()
            .Configure<IOptions<GatewayIngressOptions>>((forwarding, configured) =>
            {
                var networks = configured.Value.TrustedProxyNetworks;
                forwarding.ForwardedHeaders = networks.Length == 0
                    ? ForwardedHeaders.None
                    : ForwardedHeaders.XForwardedProto;
                forwarding.ForwardLimit = 1;
                forwarding.KnownProxies.Clear();
                forwarding.KnownIPNetworks.Clear();
                foreach (var network in networks)
                    forwarding.KnownIPNetworks.Add(IPNetwork.Parse(network));
            });
        return services;
    }
}
