namespace Gateway.Contracts.Dtos;

public record Agent365InfoDto(
    string? AgentId,
    string? BlueprintId,
    string? InstanceId,
    string? AgentIdentityObjectId = null,
    string? BlueprintObjectId = null);
