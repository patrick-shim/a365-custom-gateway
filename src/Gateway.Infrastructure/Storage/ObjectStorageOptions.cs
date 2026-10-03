namespace Gateway.Infrastructure.Storage;

public sealed class ObjectStorageOptions
{
    public const string SectionName = "ObjectStorage";

    public string ServiceUrl { get; set; } = string.Empty;
    public string AccessKey { get; set; } = string.Empty;
    public string SecretKey { get; set; } = string.Empty;
    public string BucketName { get; set; } = "a365-gateway-interactions";
    public bool ForcePathStyle { get; set; } = true;
    public bool CreateBucketIfMissing { get; set; }
}
