using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public sealed class PurviewConnectorOperation
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid ConnectorInstanceId { get; set; }
    public PurviewConnectorOperationType Type { get; set; }
    public PurviewConnectorOperationStatus Status { get; set; }
    public string CurrentStep { get; set; } = "Queued";
    public int PercentComplete { get; set; }
    public long Generation { get; set; }
    public string IdempotencyKey { get; set; } = string.Empty;
    public string RequestHash { get; set; } = string.Empty;
    public string RequestedByObjectId { get; set; } = string.Empty;
    public string CorrelationId { get; set; } = string.Empty;
    public DateTime IssuedAtUtc { get; set; }
    public DateTime ExpiresAtUtc { get; set; }
    public DateTime? LeaseExpiresAtUtc { get; set; }
    public int AttemptCount { get; set; }
    public DateTime? StartedAtUtc { get; set; }
    public DateTime? CompletedAtUtc { get; set; }
    public string? ResultHash { get; set; }
    public string? CatalogHash { get; set; }
    public string? FailureCode { get; set; }
    public string? FailureSummary { get; set; }
    public DateTime? TransportCleanedAtUtc { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];
}
