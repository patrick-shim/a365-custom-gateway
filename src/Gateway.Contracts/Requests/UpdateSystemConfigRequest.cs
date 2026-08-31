namespace Gateway.Contracts.Requests;

/// <summary>
/// A partial update of implemented registration defaults, idempotency lifetime,
/// and ingress rate limits. Compatibility-only members remain in the wire shape;
/// callers must omit them or send <see langword="null"/>.
/// </summary>
public record UpdateSystemConfigRequest(
    string? ProvisioningMode,
    string? DefaultObservabilityMode,
    bool? DefaultPurviewEnabled,
    string? DefaultPurviewMode,
    int? RetentionDaysActivityReceipts,
    int? RetentionDaysAuditEvents,
    int? RetentionDaysIdempotencyRecords,
    int? RetentionDaysOutboxMessages,
    int? RateLimitPerClient,
    int? RateLimitPerAgent,
    int? RateLimitGlobal,
    bool? ReconciliationEnabled,
    int? ReconciliationIntervalHours,
    int? StuckTransitionTimeoutDays,
    bool? UseGraphAgentRegistration,
    bool? UseCliProvisioningFallback,
    bool? DefaultAgent365ObservabilityEnabled = null,
    bool? DefaultAzureMonitorExportEnabled = null,
    bool? DefaultPromptShieldEnabled = null);
