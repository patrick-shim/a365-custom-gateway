namespace Gateway.Contracts.Dtos;

public record ProvisioningRetryEligibilityDto(
    bool Supported,
    string Reason);
