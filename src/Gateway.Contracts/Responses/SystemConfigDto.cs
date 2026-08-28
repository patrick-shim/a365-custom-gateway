using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

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
    string? AuthorizedRegistrationExternalAgentId = null);

public record UpdateFeaturesResponse(
    Guid AgentId,
    AgentFeaturesDto Features,
    DateTime UpdatedAtUtc);
