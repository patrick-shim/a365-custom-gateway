using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

/// <summary>
/// Effective gateway settings and deployment capabilities.
/// </summary>
public record SystemConfigDto(
    string ProvisioningMode,
    string DefaultObservabilityMode,
    int RetentionDaysIdempotencyRecords,
    int RateLimitPerClient,
    int RateLimitPerAgent,
    int RateLimitGlobal,
    bool? DefaultAgent365ObservabilityEnabled = null,
    bool? DefaultAzureMonitorExportEnabled = null,
    bool ProvisioningExecutionEnabled = false,
    bool DefaultPromptShieldEnabled = false,
    bool PromptShieldAvailable = false,
    string? RowVersion = null,
    AgentRegistrationDefaultsDto? RegistrationDefaults = null);

public sealed record AgentRegistrationDefaultsDto(
    string Environment = "Production",
    string? Reason = null);

public record UpdateFeaturesResponse(
    Guid AgentId,
    AgentFeaturesDto Features,
    DateTime UpdatedAtUtc);
