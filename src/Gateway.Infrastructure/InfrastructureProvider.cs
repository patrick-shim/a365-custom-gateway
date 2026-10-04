using Microsoft.Extensions.Configuration;

namespace Gateway.Infrastructure;

public static class InfrastructureProvider
{
    public const string SectionName = "Infrastructure";
    public const string Runtime = "Runtime";

    public static string Resolve(IConfiguration configuration)
    {
        if (configuration.GetValue<bool>("DatabaseAttestation:Enabled") ||
            configuration.GetSection("MaintenanceCutover").Exists() ||
            configuration.GetSection("BootstrapCapabilities:Preparation").Exists())
            throw new InvalidOperationException("Azure database upgrade and capability-preparation configuration is retired. Use runtime bootstrap.");
        var value = configuration[$"{SectionName}:Provider"]
            ?? configuration["INFRASTRUCTURE_PROVIDER"]
            ?? Runtime;
        if (string.Equals(value, Runtime, StringComparison.OrdinalIgnoreCase)) return Runtime;
        throw new InvalidOperationException("Infrastructure:Provider must be Runtime. Azure hosting has been retired.");
    }

}
