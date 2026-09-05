using Gateway.AdminUi.Models;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Services;

public interface IGatewayApiClient
{
    Task<GatewayHealthStatus> GetHealthAsync(CancellationToken cancellationToken = default);

    Task<GatewayHealthStatus> GetReadinessAsync(CancellationToken cancellationToken = default);

    Task<AgentListResponse> GetAgentsAsync(
        AgentListQuery? query = null,
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<AgentDetailDto>> GetAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<AgentIngressCredentialListResponse> GetAgentIngressCredentialsAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<IssueAgentIngressCredentialResponse> IssueAgentIngressCredentialAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<RevokeAgentIngressCredentialResponse> RevokeAgentIngressCredentialAsync(
        Guid agentId,
        Guid credentialId,
        CancellationToken cancellationToken = default);

    Task<AgentIdentityBlueprintListResponse> GetAgentIdentityBlueprintsAsync(
        CancellationToken cancellationToken = default);

    Task<PurviewPolicyProfileListResponse> GetPurviewPolicyProfilesAsync(
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionCapabilitiesResponse>> GetProtectionCapabilitiesAsync(
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<PurviewTenantConnectionResponse>> GetPurviewTenantConnectionAsync(
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationReviewTicket>> ReviewPurviewTenantConnectionAsync(
        ReviewPurviewTenantConnectionRequest request,
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationConfirmationTicket>>
        ConfirmProtectionOperationReviewAsync(
            ProtectionOperationReviewTicket review,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationAcceptedResponse>>
        StartPurviewTenantConnectionOperationAsync(
            ProtectionOperationConfirmationTicket confirmation,
            Guid idempotencyKey,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationAcceptedResponse>>
        CompletePurviewTenantConnectionOperationAsync(
            Guid operationId,
            PurviewTenantConnectionEvidenceDto evidence,
            ProtectionOperationConfirmationTicket confirmation,
            Guid idempotencyKey,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationReviewTicket>>
        ReviewPurviewTenantConnectionCompletionAsync(
            Guid operationId,
            Guid inventoryGenerationId,
            PurviewTenantConnectionEvidenceDto evidence,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<PurviewSensitiveInformationTypeListResponse>>
        GetPurviewSensitiveInformationTypesAsync(
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<PurviewKnowYourDataResponse>> GetPurviewKnowYourDataAsync(
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationReviewTicket>>
        ReviewPurviewKnowYourDataOperationAsync(
            ReviewPurviewKnowYourDataOperationRequest request,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationAcceptedResponse>>
        StartPurviewKnowYourDataOperationAsync(
            ProtectionOperationConfirmationTicket confirmation,
            Guid idempotencyKey,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<PurviewDlpProfileListResponse>> GetPurviewDlpProfilesAsync(
        CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationReviewTicket>>
        ReviewPurviewDlpProfileOperationAsync(
            ReviewPurviewDlpProfileOperationRequest request,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationAcceptedResponse>>
        StartPurviewDlpProfileOperationAsync(
            ProtectionOperationConfirmationTicket confirmation,
            Guid idempotencyKey,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationAcceptedResponse>>
        ReconcilePurviewDlpProfileAsync(
            Guid profileId,
            ProtectionOperationConfirmationTicket confirmation,
            Guid idempotencyKey,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationReviewTicket>>
        ReviewReconcilePurviewDlpProfileAsync(
            Guid profileId,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationAcceptedResponse>>
        ValidatePurviewDlpProfileRuntimeAsync(
            Guid profileId,
            ProtectionOperationConfirmationTicket confirmation,
            Guid idempotencyKey,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionOperationReviewTicket>>
        ReviewValidatePurviewDlpRuntimeAsync(
            Guid profileId,
            string expectedRowVersion,
            CancellationToken cancellationToken = default);

    Task<GatewayApiResource<ProtectionAdminOperationResponse>>
        GetProtectionAdminOperationAsync(
            Guid operationId,
            CancellationToken cancellationToken = default);

    Task<RegisterAgentResponse> RegisterAgentAsync(
        RegisterAgentRequest request,
        CancellationToken cancellationToken = default);

    Task<UpdateFeaturesResponse> UpdateAgentFeaturesAsync(
        Guid agentId,
        UpdateFeaturesRequest request,
        CancellationToken cancellationToken = default);

    Task<AgentStateChangeResponse> EnableAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<AgentStateChangeResponse> DisableAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<AsyncOperationResponse> RetryProvisioningAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<DeleteAgentResponse> DeleteAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<AuditEventListResponse> GetAgentAuditEventsAsync(
        Guid agentId,
        AuditEventQuery? query = null,
        CancellationToken cancellationToken = default);

    Task<ProvisioningHistoryResponse> GetProvisioningHistoryAsync(
        Guid agentId,
        CancellationToken cancellationToken = default);

    Task<OperationStatusDto> GetOperationStatusAsync(
        Guid operationId,
        CancellationToken cancellationToken = default);

    Task<CompleteAgent365RegistrationResponse> CompleteAgent365RegistrationAsync(
        Guid operationId,
        CancellationToken cancellationToken = default);

    Task<SystemConfigDto> GetSystemConfigAsync(CancellationToken cancellationToken = default);

    Task<SystemConfigDto> UpdateSystemConfigAsync(
        UpdateSystemConfigRequest request,
        CancellationToken cancellationToken = default);
}
