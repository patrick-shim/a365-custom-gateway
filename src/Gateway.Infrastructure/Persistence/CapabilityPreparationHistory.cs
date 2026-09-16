namespace Gateway.Infrastructure.Persistence;

internal sealed class CapabilityPreparationHistory
{
    public Guid Id { get; set; }
    public Guid DeploymentOwnershipId { get; set; }
    public string ApprovedPlanFingerprint { get; set; } = string.Empty;
    public string ReceiptFingerprint { get; set; } = string.Empty;
    public string? PreviousReceiptFingerprint { get; set; }
    public string OriginalCapabilityFactsHash { get; set; } = string.Empty;
    public string PriorCapabilityFactsJson { get; set; } = string.Empty;
    public string TargetCapabilityFactsJson { get; set; } = string.Empty;
    public string ReceiptJson { get; set; } = string.Empty;
    public DateTime RecordedAtUtc { get; set; }
}
