namespace Gateway.Observability;

public sealed class ObservabilityOptions
{
    public const string SectionName = "Observability";

    public string? ApplicationInsightsConnectionString { get; set; }
}
