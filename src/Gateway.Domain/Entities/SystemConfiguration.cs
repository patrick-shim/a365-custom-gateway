using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class SystemConfiguration
{
    public Guid Id { get; set; }
    public string DefaultObservabilityMode { get; set; } = nameof(ObservabilityMode.Agent365);
    public bool DefaultPromptShieldEnabled { get; set; }
    public int RetentionDaysIdempotencyRecords { get; set; }
    public int RateLimitPerClient { get; set; }
    public int RateLimitPerAgent { get; set; }
    public int RateLimitGlobal { get; set; }
    public byte[] RowVersion { get; set; } = [];
    public DateTime UpdatedAtUtc { get; set; }
}
