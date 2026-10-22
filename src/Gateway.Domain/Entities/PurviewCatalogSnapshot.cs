namespace Gateway.Domain.Entities;

public sealed class PurviewCatalogSnapshot
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid ConnectorInstanceId { get; set; }
    public Guid OperationId { get; set; }
    public long Generation { get; set; }
    public string CatalogHash { get; set; } = string.Empty;
    public string CatalogJson { get; set; } = string.Empty;
    public DateTime RetrievedAtUtc { get; set; }
    public DateTime AcceptedAtUtc { get; set; }
    public int PolicyCount { get; set; }
    public int CompatiblePolicyCount { get; set; }
    public int IncompatiblePolicyCount { get; set; }
}
