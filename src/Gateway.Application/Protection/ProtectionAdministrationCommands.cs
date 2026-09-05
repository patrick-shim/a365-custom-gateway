using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Protection;

public sealed record ReviewPurviewTenantConnectionCommand(
    ProtectionActor Actor,
    ReviewPurviewTenantConnectionRequest Request,
    Guid CorrelationId) : IRequest<ProtectionOperationReviewResponse>;

public sealed record ReviewPurviewTenantConnectionCompletionCommand(
    ProtectionActor Actor,
    Guid OperationId,
    ReviewPurviewTenantConnectionCompletionRequest Request,
    Guid CorrelationId) : IRequest<ProtectionOperationReviewResponse>;

public sealed record ReviewPurviewKnowYourDataCommand(
    ProtectionActor Actor,
    ReviewPurviewKnowYourDataOperationRequest Request,
    Guid CorrelationId) : IRequest<ProtectionOperationReviewResponse>;

public sealed record ReviewPurviewDlpProfileCommand(
    ProtectionActor Actor,
    ReviewPurviewDlpProfileOperationRequest Request,
    Guid CorrelationId) : IRequest<ProtectionOperationReviewResponse>;

public sealed record ReviewReconcilePurviewDlpProfileCommand(
    ProtectionActor Actor,
    Guid ProfileId,
    ReviewReconcilePurviewDlpProfileRequest Request,
    Guid CorrelationId) : IRequest<ProtectionOperationReviewResponse>;

public sealed record ReviewValidatePurviewDlpRuntimeCommand(
    ProtectionActor Actor,
    Guid ProfileId,
    ReviewValidatePurviewDlpRuntimeRequest Request,
    Guid CorrelationId) : IRequest<ProtectionOperationReviewResponse>;

public sealed record ConfirmProtectionOperationReviewCommand(
    ProtectionActor Actor,
    ConfirmProtectionOperationReviewRequest Request)
    : IRequest<ProtectionOperationConfirmationResponse>;

public sealed record StartPurviewTenantConnectionCommand(
    ProtectionActor Actor,
    StartPurviewTenantConnectionOperationRequest Request)
    : IRequest<ProtectionOperationAcceptedResponse>;

public sealed record CompletePurviewTenantConnectionCommand(
    ProtectionActor Actor,
    Guid OperationId,
    CompletePurviewTenantConnectionOperationRequest Request)
    : IRequest<ProtectionOperationAcceptedResponse>;

public sealed record StartPurviewKnowYourDataCommand(
    ProtectionActor Actor,
    StartPurviewKnowYourDataOperationRequest Request)
    : IRequest<ProtectionOperationAcceptedResponse>;

public sealed record StartPurviewDlpProfileCommand(
    ProtectionActor Actor,
    StartPurviewDlpProfileOperationRequest Request)
    : IRequest<ProtectionOperationAcceptedResponse>;

public sealed record ReconcilePurviewDlpProfileCommand(
    ProtectionActor Actor,
    Guid ProfileId,
    ReconcilePurviewDlpProfileRequest Request)
    : IRequest<ProtectionOperationAcceptedResponse>;

public sealed record ValidatePurviewDlpProfileRuntimeCommand(
    ProtectionActor Actor,
    Guid ProfileId,
    ValidatePurviewDlpProfileRuntimeRequest Request)
    : IRequest<ProtectionOperationAcceptedResponse>;

internal sealed record PurviewTenantConnectionReviewPayload(Guid TenantId);

internal sealed record PurviewTenantConnectionCompletionReviewPayload(
    Guid SourceOperationId,
    Guid InventoryGenerationId,
    string EvidenceDigest);

internal sealed record PurviewKnowYourDataReviewPayload(
    Guid TenantConnectionId,
    Guid InventoryGenerationId,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string Mode,
    IReadOnlyList<string> Activities,
    bool IngestionEnabled);

internal sealed record PurviewDlpProfileReviewPayload(
    Guid ProfileId,
    Guid TenantConnectionId,
    Guid BlueprintApplicationId,
    string DisplayName,
    Guid InventoryGenerationId,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string Mode,
    IReadOnlyList<string> Activities,
    IReadOnlyList<Contracts.Dtos.PurviewDlpRuleActionDto> Actions);
