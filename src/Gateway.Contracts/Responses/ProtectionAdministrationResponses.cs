using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public sealed record ProtectionCapabilitiesResponse(
    IReadOnlyList<ProtectionCapabilityDto> Items);

public sealed record PurviewTenantConnectionResponse(
    PurviewTenantConnectionDto? Connection);

public sealed record PurviewSensitiveInformationTypeListResponse(
    Guid GenerationId,
    Guid TenantId,
    DateTime RetrievedAtUtc,
    DateTime ExpiresAtUtc,
    bool IsExpired,
    IReadOnlyList<PurviewSensitiveInformationTypeDto> Items);

public sealed record PurviewKnowYourDataResponse(
    PurviewKnowYourDataConfigurationDto? Configuration);

public sealed record PurviewDlpProfileListResponse(
    IReadOnlyList<PurviewDlpProfileDto> Items);

/// <summary>
/// A review response grants no provider mutation by itself. Its short-lived
/// review value can only be exchanged through an explicit confirmation action.
/// </summary>
public sealed record ProtectionOperationReviewResponse(
    Guid ReviewTokenId,
    string ReviewToken,
    string ReviewedPayloadHash,
    DateTime ExpiresAtUtc,
    ProtectionOperationReviewSummaryDto Review);

/// <summary>
/// Returned once after explicit user confirmation. The confirmation value is
/// Gateway-issued and is never persisted in clear form.
/// </summary>
public sealed record ProtectionOperationConfirmationResponse(
    Guid ReviewTokenId,
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    DateTime ExpiresAtUtc);

public sealed record ProtectionOperationAcceptedResponse(
    Guid OperationId,
    string Status,
    Guid CorrelationId,
    PurviewCompanionLaunchDto? CompanionLaunch = null);

public sealed record ProtectionAdminOperationResponse(
    ProtectionAdminOperationDto Operation);
