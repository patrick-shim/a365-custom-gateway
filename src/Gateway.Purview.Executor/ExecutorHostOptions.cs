namespace Gateway.Purview.Executor;

internal sealed class ExecutorHostOptions
{
    public const string SectionName = "Executor";
    public PurviewExecutorBinding? Binding { get; set; }
    public string? ClaimsContainerUri { get; set; }
    public string? RuntimeManifestDigest { get; set; }
    public int OperationTimeoutSeconds { get; set; } = 195;
}
