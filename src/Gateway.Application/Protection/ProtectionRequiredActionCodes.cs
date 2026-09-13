namespace Gateway.Application.Protection;

public static class ProtectionRequiredActionCodes
{
    public const string CompletePurviewTenantConnection =
        nameof(CompletePurviewTenantConnection);
    public const string WaitingForRegisteredBlueprint = nameof(WaitingForRegisteredBlueprint);
    public const string ReviewExistingSharedPolicy = nameof(ReviewExistingSharedPolicy);
    public const string RefreshInventoryAndReviewPolicyForResolvedBlueprint = nameof(RefreshInventoryAndReviewPolicyForResolvedBlueprint);
}
