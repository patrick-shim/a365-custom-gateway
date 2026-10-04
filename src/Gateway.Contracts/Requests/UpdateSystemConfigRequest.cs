namespace Gateway.Contracts.Requests;

/// <summary>
/// A partial update of implemented registration defaults, idempotency lifetime,
/// and ingress rate limits.
/// </summary>
public record UpdateSystemConfigRequest(
    string? DefaultObservabilityMode,
    int? RetentionDaysIdempotencyRecords,
    int? RateLimitPerClient,
    int? RateLimitPerAgent,
    int? RateLimitGlobal,
    bool? DefaultAgent365ObservabilityEnabled = null,
    bool? DefaultAzureMonitorExportEnabled = null,
    bool? DefaultPromptShieldEnabled = null,
    Guid? IdempotencyKey = null,
    string? ExpectedRowVersion = null);
