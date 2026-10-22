using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public sealed class PurviewConnectorStateRecord
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid ConnectorInstanceId { get; set; }
    public string ConnectorProfile { get; set; } = "LocalWindows";
    public PurviewConnectorState State { get; set; }
    public string RefreshMode { get; set; } = "Manual";
    public long NextGeneration { get; set; } = 1;
    public DateTime? LastHeartbeatAtUtc { get; set; }
    public DateTime? LastAttemptedRefreshAtUtc { get; set; }
    public DateTime? LastSuccessfulRefreshAtUtc { get; set; }
    public DateTime? CatalogRetrievedAtUtc { get; set; }
    public int PolicyCount { get; set; }
    public int CompatiblePolicyCount { get; set; }
    public int IncompatiblePolicyCount { get; set; }
    public string CatalogVerificationStatus { get; set; } = "Unavailable";
    public Guid? CurrentOperationId { get; set; }
    public string? LastFailureCode { get; set; }
    public string? LastCorrelationId { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];
}
