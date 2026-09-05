using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public sealed record ReviewPurviewTenantConnectionRequest(
    Guid TenantId,
    string ExpectedRowVersion);

public sealed record StartPurviewTenantConnectionOperationRequest(
    Guid TenantId,
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

public sealed record CompletePurviewTenantConnectionOperationRequest(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion,
    Guid InventoryGenerationId,
    string EvidenceDigest,
    PurviewTenantConnectionEvidenceDto Evidence);

public sealed record ReviewPurviewTenantConnectionCompletionRequest(
    Guid OperationId,
    Guid InventoryGenerationId,
    string EvidenceDigest,
    string ExpectedRowVersion,
    PurviewTenantConnectionEvidenceDto Evidence);

public sealed record ReviewPurviewKnowYourDataOperationRequest(
    Guid TenantConnectionId,
    PurviewSensitiveInformationTypeSelectionDto SensitiveInformationType,
    string Mode,
    IReadOnlyList<string> Activities,
    bool IngestionEnabled,
    string ExpectedRowVersion);

public sealed record StartPurviewKnowYourDataOperationRequest(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

public sealed record ReviewPurviewDlpProfileOperationRequest(
    Guid? ProfileId,
    Guid TenantConnectionId,
    Guid BlueprintApplicationId,
    string DisplayName,
    PurviewSensitiveInformationTypeSelectionDto SensitiveInformationType,
    string Mode,
    IReadOnlyList<string> Activities,
    IReadOnlyList<PurviewDlpRuleActionDto> Actions,
    string ExpectedRowVersion);

public sealed record StartPurviewDlpProfileOperationRequest(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

public sealed record ReconcilePurviewDlpProfileRequest(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

public sealed record ReviewReconcilePurviewDlpProfileRequest(
    Guid ProfileId,
    string ExpectedRowVersion);

public sealed record ValidatePurviewDlpProfileRuntimeRequest(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

public sealed record ReviewValidatePurviewDlpRuntimeRequest(
    Guid ProfileId,
    string ExpectedRowVersion);

/// <summary>
/// A common confirmation shape for clients that dispatch reviewed operations by
/// operation type. The confirmation value is Gateway-issued, short-lived, and
/// single-use; it is never a provider or identity token.
/// </summary>
public sealed record ConfirmProtectionAdminOperationRequest(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

public sealed record ConfirmProtectionOperationReviewRequest(
    Guid ReviewTokenId,
    string ReviewToken);
