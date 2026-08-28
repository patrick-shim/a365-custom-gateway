namespace Gateway.Domain.Models;

public sealed record AgentIdentityBlueprintCatalogItem(
    Guid BlueprintObjectId,
    Guid BlueprintClientId,
    string DisplayName,
    bool IsAgent365Compatible,
    string? Agent365CompatibilityIssue);

public static class AgentIdentityBlueprintCompatibilityIssues
{
    public const string ManagerApplicationsNotConfigured =
        "ManagerApplicationsNotConfigured";

    public const string MissingRequiredManagerApplications =
        "MissingRequiredManagerApplications";
}
