using System.Net;

namespace Gateway.Api.Options;

public sealed class GatewayIngressOptions
{
    public const string SectionName = "GatewayIngress";

    public string[] TrustedProxyNetworks { get; set; } = [];

    public static bool IsValid(GatewayIngressOptions options) =>
        options.TrustedProxyNetworks is { Length: <= 8 } networks &&
        networks.Distinct(StringComparer.Ordinal).Count() == networks.Length &&
        networks.All(value => IPNetwork.TryParse(value, out var network) &&
            network.PrefixLength > 0 &&
            (!network.BaseAddress.IsIPv4MappedToIPv6 || network.PrefixLength > 96) &&
            network.ToString() == value);
}
