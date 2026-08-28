namespace Gateway.Domain.Models;

public sealed record Agent365DelegatedRegistryRequest(
    Guid RequestCorrelationId,
    Guid PlannedRegistrationId,
    string DisplayName,
    string? Description,
    string SourceAgentId,
    Guid OwnerObjectId,
    Guid CreatedByObjectId,
    Guid AgentIdentityObjectId,
    Guid BlueprintClientId,
    DateTimeOffset SourceCreatedAtUtc,
    DateTimeOffset SourceLastModifiedAtUtc);
