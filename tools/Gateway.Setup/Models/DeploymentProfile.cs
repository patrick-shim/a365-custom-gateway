namespace Gateway.Setup.Models;

internal enum DeploymentProfile
{
    QuickDevelopment,
    StagingFoundation,
    ProductionSafeFoundation
}

internal static class DeploymentProfileExtensions
{
    public static string DisplayName(this DeploymentProfile profile) => profile switch
    {
        DeploymentProfile.QuickDevelopment => "Quick development",
        DeploymentProfile.StagingFoundation => "Staging foundation",
        DeploymentProfile.ProductionSafeFoundation => "Production-safe foundation",
        _ => throw new ArgumentOutOfRangeException(nameof(profile), profile, null)
    };
}
