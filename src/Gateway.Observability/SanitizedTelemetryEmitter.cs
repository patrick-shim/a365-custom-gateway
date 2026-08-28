using System.Diagnostics;

namespace Gateway.Observability;

public static class SanitizedTelemetryEmitter
{
    private static readonly HashSet<string> RecordTypes = new(StringComparer.Ordinal)
    {
        "activity",
        "interaction"
    };

    private static readonly HashSet<string> Operations = new(StringComparer.Ordinal)
    {
        "invoke_agent",
        "execute_tool",
        "chat",
        "output_messages",
        "custom"
    };

    public static void EmitAzureMonitorMirror(
        Guid agentRegistrationId,
        Guid eventId,
        string recordType,
        string operation,
        DateTime startedAtUtc,
        DateTime endedAtUtc)
    {
        if (!RecordTypes.Contains(recordType))
            throw new ArgumentOutOfRangeException(nameof(recordType));
        if (!Operations.Contains(operation))
            throw new ArgumentOutOfRangeException(nameof(operation));

        var start = NormalizeUtc(startedAtUtc);
        var end = NormalizeUtc(endedAtUtc);
        if (end < start)
            end = start;

        using var activity = GatewayActivitySource.Instance.StartActivity(
            GatewayActivitySource.Operations.MirrorSanitizedTelemetry,
            ActivityKind.Internal,
            default(ActivityContext),
            tags: null,
            links: null,
            startTime: start);

        if (activity is not null)
        {
            activity.SetTag("gateway.agent.registration_id", agentRegistrationId.ToString("D"));
            activity.SetTag("gateway.event.id", eventId.ToString("D"));
            activity.SetTag("gateway.record.type", recordType);
            activity.SetTag("gateway.operation", operation);
            activity.SetTag("gateway.export.destination", "azure_monitor");
            activity.SetStatus(ActivityStatusCode.Ok);
            activity.SetEndTime(end);
        }

        GatewayObservabilityMetrics.RecordAzureMonitorEmission(recordType, operation);
    }

    private static DateTime NormalizeUtc(DateTime value)
    {
        return value.Kind switch
        {
            DateTimeKind.Utc => value,
            DateTimeKind.Local => value.ToUniversalTime(),
            _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
        };
    }
}
