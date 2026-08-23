namespace Gateway.Observability;

public sealed class ObservabilityOptions
{
    public const string SectionName = "Observability";

    public string? ApplicationInsightsConnectionString { get; set; }
    public string? Agent365OtlpEndpoint { get; set; } = "https://agent365.svc.cloud.microsoft";
    public bool EnableAgent365Export { get; set; }
}
