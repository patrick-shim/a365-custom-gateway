using Gateway.AdminUi.Models;
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
