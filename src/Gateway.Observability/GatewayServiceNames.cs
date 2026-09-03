namespace Gateway.Observability;

/// <summary>
/// Distinct OpenTelemetry <c>service.name</c> values, one per deployed host.
/// </summary>
/// <remarks>
/// Azure Monitor projects <c>service.name</c> onto <c>AppRoleName</c>. Both hosts
/// previously reported the bare activity source name, so every span in
/// Application Insights looked identical and API traffic could not be told apart
/// from provisioning worker traffic. Keeping <see cref="GatewayActivitySource.Name"/>
/// as the prefix means existing queries that filter the gateway by role name
/// still match both hosts.
/// </remarks>
public static class GatewayServiceNames
{
    public const string Api = GatewayActivitySource.Name + ".Api";

    public const string ProvisioningWorker = GatewayActivitySource.Name + ".ProvisioningWorker";
}
