using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record AgentDetailDto(
    Guid AgentId,
    string ExternalAgentId,
    string Name,
    string? Description,
    string Status,
    string Environment,
    Agent365InfoDto? Agent365,
    AgentFeaturesDto? Features,
    DateTime? LastActivityAtUtc,
    DateTime CreatedAtUtc,
    DateTime UpdatedAtUtc,
    string OwnerObjectId,
    ProvisioningStatusDto? Provisioning,
    string CreatedByObjectId,
    string UpdatedByObjectId,
    byte[] RowVersion,
    LinksDto? Links,
    ProvisioningRetryEligibilityDto? RetryProvisioning = null);
