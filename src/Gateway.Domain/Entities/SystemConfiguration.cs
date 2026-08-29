using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class SystemConfiguration
{
    public Guid Id { get; set; }
    public string ProvisioningMode { get; set; } = string.Empty;
    public string DefaultObservabilityMode { get; set; } = nameof(ObservabilityMode.Agent365);
    public bool DefaultPurviewEnabled { get; set; }
    public string? DefaultPurviewMode { get; set; }
    public bool DefaultPromptShieldEnabled { get; set; }
    public int RetentionDaysActivityReceipts { get; set; }
    public int RetentionDaysAuditEvents { get; set; }
    public int RetentionDaysIdempotencyRecords { get; set; }
    public int RetentionDaysOutboxMessages { get; set; }
    public int RateLimitPerClient { get; set; }
    public int RateLimitPerAgent { get; set; }
    public int RateLimitGlobal { get; set; }
    public bool ReconciliationEnabled { get; set; }
    public int ReconciliationIntervalHours { get; set; }
    public int StuckTransitionTimeoutDays { get; set; }
    public bool UseGraphAgentRegistration { get; set; }
    public bool UseCliProvisioningFallback { get; set; }
    public byte[] RowVersion { get; set; } = [];
    public DateTime UpdatedAtUtc { get; set; }
}
