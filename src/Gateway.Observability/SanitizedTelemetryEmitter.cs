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

    /// <summary>
    /// Emits the sanitized Azure Monitor mirror span for one activity or interaction.
    /// Returns <c>true</c> only when a span was actually recorded, so a caller can tell
    /// a mirrored event from one that silently produced nothing.
    /// </summary>
    public static bool EmitAzureMonitorMirror(
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

        // The mirror carries the original event's timestamps, which routinely predate the
        // worker run that processes the message by minutes or hours. Inheriting the ambient
        // processing span as a parent would therefore produce a child whose lifetime falls
        // outside its parent's, which is a malformed trace. Start it as a root span instead
        // and keep the correlation as a tag.
        var ambient = Activity.Current;
        bool recorded;
        Activity.Current = null;
        try
        {
            using var activity = GatewayActivitySource.Instance.StartActivity(
                GatewayActivitySource.Operations.MirrorSanitizedTelemetry,
                ActivityKind.Internal,
                default(ActivityContext),
                tags: null,
                links: null,
                startTime: start);

            recorded = activity is not null;
            if (activity is not null)
            {
                activity.SetTag("gateway.agent.registration_id", agentRegistrationId.ToString("D"));
                activity.SetTag("gateway.event.id", eventId.ToString("D"));
                activity.SetTag("gateway.record.type", recordType);
                activity.SetTag("gateway.operation", operation);
                activity.SetTag("gateway.export.destination", "azure_monitor");
                if (ambient is not null)
                {
                    activity.SetTag(
                        "gateway.correlation.trace_id",
                        ambient.TraceId.ToHexString());
                }

                activity.SetStatus(ActivityStatusCode.Ok);
                activity.SetEndTime(end);
            }
        }
        finally
        {
            Activity.Current = ambient;
        }

        GatewayObservabilityMetrics.RecordAzureMonitorEmission(recordType, operation, recorded);
        return recorded;
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
