using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

/// <summary>
/// Effective configuration and deployment capabilities. Persisted compatibility
/// members remain in this response for wire compatibility but are read-only and
/// do not advertise an implemented runtime control.
/// </summary>
public record SystemConfigDto(
    string ProvisioningMode,
    string DefaultObservabilityMode,
    bool DefaultPurviewEnabled,
    string? DefaultPurviewMode,
    int RetentionDaysActivityReceipts,
    int RetentionDaysAuditEvents,
    int RetentionDaysIdempotencyRecords,
    int RetentionDaysOutboxMessages,
    int RateLimitPerClient,
    int RateLimitPerAgent,
    int RateLimitGlobal,
    bool ReconciliationEnabled,
    int ReconciliationIntervalHours,
    int StuckTransitionTimeoutDays,
    bool UseGraphAgentRegistration,
    bool UseCliProvisioningFallback,
    bool? DefaultAgent365ObservabilityEnabled = null,
    bool? DefaultAzureMonitorExportEnabled = null,
    bool ProvisioningExecutionEnabled = false,
    bool PurviewPolicyProvisioningEnabled = false,
    bool DefaultPromptShieldEnabled = false,
    bool PromptShieldAvailable = false);

public record UpdateFeaturesResponse(
    Guid AgentId,
    AgentFeaturesDto Features,
    DateTime UpdatedAtUtc);
