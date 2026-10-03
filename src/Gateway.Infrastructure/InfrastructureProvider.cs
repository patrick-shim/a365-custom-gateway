using Microsoft.Extensions.Configuration;

namespace Gateway.Infrastructure;

public static class InfrastructureProvider
{
    public const string SectionName = "Infrastructure";
    public const string Azure = "Azure";
    public const string Portable = "Portable";

    public static string Resolve(IConfiguration configuration)
    {
        var value = configuration[$"{SectionName}:Provider"]
            ?? configuration["INFRASTRUCTURE_PROVIDER"]
            ?? Azure;
        return string.Equals(value, Portable, StringComparison.OrdinalIgnoreCase)
            ? Portable
            : Azure;
    }

    public static bool IsPortable(IConfiguration configuration) =>
        Resolve(configuration) == Portable;
}
