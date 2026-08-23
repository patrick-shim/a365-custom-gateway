namespace Gateway.Infrastructure.Storage;

public sealed class BlobStorageOptions
{
    public string? ConnectionString { get; set; }
    public string? ServiceUri { get; set; }
    public string ContainerName { get; set; } = "a365-gateway-interactions";
}
