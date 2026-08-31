namespace Gateway.Domain.Models;

public sealed record PurviewPolicyProvisioningRequest(
    Guid ProfileId,
    string DisplayName,
    string Template,
    string Mode,
    string CollectionPolicyName,
    string DlpPolicyName,
    string DlpRuleName,
    string BlueprintApplicationId,
    string BlueprintDisplayName,
    string? ExpectedCollectionPolicyId = null,
    string? ExpectedDlpPolicyId = null,
    string? ExpectedDlpRuleId = null,
    IReadOnlyList<string>? ExpectedPriorDlpBlueprintApplicationIds = null,
    IReadOnlyList<string>? ExpectedDlpBlueprintApplicationIds = null);

public static class PurviewPolicyLocationContract
{
    public const string EnterpriseAiAppsCollectionLocationId =
        "ee1680d0-702f-4090-b26c-c49091e86531";
    public const string ApplicationWorkload = "Applications";
    public const string EntraLocationSource = "Entra";
    public const string CollectionLocationType = "Group";
    public const string DlpLocationType = "Individual";
    public const string ApplicationEnforcementPlane = "Application";
}

public sealed record PurviewPolicyRuleActionEvidence(
    string Setting,
    string Value);

public sealed record PurviewPolicyLocationReadbackEvidence(
    string Workload,
    string LocationSource,
    string LocationType,
    IReadOnlyList<string> LocationIds);

public sealed record PurviewPolicyReadbackEvidence(
    string CollectionMode,
    IReadOnlyList<string> CollectionActivities,
    IReadOnlyList<string> CollectionEnforcementPlanes,
    IReadOnlyList<string> CollectionSensitiveTypeIds,
    bool CollectionIngestionEnabled,
    PurviewPolicyLocationReadbackEvidence CollectionLocation,
    string DlpMode,
    IReadOnlyList<string> DlpEnforcementPlanes,
    PurviewPolicyLocationReadbackEvidence DlpLocation,
    IReadOnlyList<string> ClassifierNames,
    IReadOnlyList<PurviewPolicyRuleActionEvidence> RuleActions,
    bool HasExclusions,
    bool HasBypass,
    bool HasExtraConditions,
    bool HasExtraActions);

public sealed record PurviewPolicyProvisioningResult(
    string CollectionPolicyId,
    string DlpPolicyId,
    string DlpRuleId,
    IReadOnlyList<string> DlpBlueprintApplicationIds,
    PurviewPolicyReadbackEvidence Evidence,
    DateTimeOffset VerifiedAtUtc);
