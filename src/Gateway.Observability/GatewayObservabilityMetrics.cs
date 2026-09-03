using System.Diagnostics.Metrics;

namespace Gateway.Observability;

public static class GatewayObservabilityMetrics
{
    public const string MeterName = "Gateway.Observability";

    private static readonly Meter Meter = new(MeterName);
    private static readonly Counter<long> EmittedEvents = Meter.CreateCounter<long>(
        "gateway.observability.azure_monitor.emitted_events",
        unit: "{event}",
        description: "Sanitized activity and interaction events offered to the Azure Monitor pipeline, split by whether a span was actually recorded.");

    internal static void RecordAzureMonitorEmission(
        string recordType,
        string operation,
        bool recorded)
    {
        EmittedEvents.Add(
            1,
            new KeyValuePair<string, object?>("gateway.record.type", recordType),
            new KeyValuePair<string, object?>("gateway.operation", operation),
            // A constant dimension would make the counter unfalsifiable. Report the real
            // outcome so an un-mirrored event is visible instead of being counted as sent.
            new KeyValuePair<string, object?>(
                "gateway.export.result",
                recorded ? "recorded" : "not_recorded"));
    }
}
