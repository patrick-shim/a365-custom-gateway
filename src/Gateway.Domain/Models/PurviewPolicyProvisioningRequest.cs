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
    string BlueprintDisplayName);

public sealed record PurviewPolicyProvisioningResult(
    string CollectionPolicyId,
    string DlpPolicyId,
    string DlpRuleId,
    IReadOnlyList<string> BlueprintApplicationIds,
    DateTimeOffset VerifiedAtUtc);
