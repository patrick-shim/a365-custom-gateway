namespace Gateway.Setup.Models;

internal sealed record AzureSubscription(
    Guid SubscriptionId,
    Guid TenantId,
    string Name,
    bool IsDefault,
    string State)
{
    public string DisplayLabel => $"{Name} · {SubscriptionId:D}";
}
