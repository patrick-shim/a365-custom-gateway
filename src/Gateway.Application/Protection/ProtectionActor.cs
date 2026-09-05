namespace Gateway.Application.Protection;

public sealed record ProtectionActor
{
    public Guid TenantId { get; }

    public string ObjectId { get; }

    public ProtectionActor(Guid tenantId, string objectId)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(tenantId, Guid.Empty);
        ArgumentException.ThrowIfNullOrWhiteSpace(objectId);
        if (!Guid.TryParse(objectId, out var parsedObjectId) || parsedObjectId == Guid.Empty)
        {
            throw new ArgumentException(
                "A non-empty Microsoft Entra user object identifier is required.",
                nameof(objectId));
        }

        TenantId = tenantId;
        ObjectId = parsedObjectId.ToString("D");
    }
}
