namespace Gateway.Contracts.Dtos;

public record ProvisioningStatusDto(
    string? CurrentStep,
    int PercentComplete,
    string? LastError);
