namespace Gateway.Contracts.Dtos;

public record ActorDto(
    string Type,
    string? TenantUserObjectId = null);
