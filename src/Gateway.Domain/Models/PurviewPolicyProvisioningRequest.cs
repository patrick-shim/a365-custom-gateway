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
    IReadOnlyList<string>? ExpectedPriorBlueprintApplicationIds = null,
    IReadOnlyList<string>? ExpectedBlueprintApplicationIds = null);

public sealed record PurviewPolicyRuleActionEvidence(
    string Setting,
    string Value);

public sealed record PurviewPolicyReadbackEvidence(
    string CollectionMode,
    IReadOnlyList<string> CollectionActivities,
    IReadOnlyList<string> CollectionEnforcementPlanes,
    IReadOnlyList<string> CollectionSensitiveTypeIds,
    bool CollectionIngestionEnabled,
    string DlpMode,
    IReadOnlyList<string> DlpEnforcementPlanes,
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
    IReadOnlyList<string> BlueprintApplicationIds,
    PurviewPolicyReadbackEvidence Evidence,
    DateTimeOffset VerifiedAtUtc);
