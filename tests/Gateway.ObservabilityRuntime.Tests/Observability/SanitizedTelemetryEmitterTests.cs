using System.Diagnostics;
using System.Diagnostics.Metrics;
using FluentAssertions;
using Gateway.Observability;

namespace Gateway.ObservabilityRuntime.Tests.Observability;

// Asserts on process-global span and meter listeners, so it must not run alongside any
// other class that emits gateway telemetry.
[Collection(TelemetryCollection.Name)]
public sealed class SanitizedTelemetryEmitterTests
{
    private const string EmittedEventsInstrument =
        "gateway.observability.azure_monitor.emitted_events";

    [Fact]
    public void Emit_ReportsNotRecorded_WhenNothingIsListeningForGatewaySpans()
    {
        using var measurements = new EmittedEventRecorder();

        var recorded = SanitizedTelemetryEmitter.EmitAzureMonitorMirror(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "activity",
            "invoke_agent",
            DateTime.UtcNow.AddMinutes(-5),
            DateTime.UtcNow.AddMinutes(-4));

        recorded.Should().BeFalse(
            "no listener means no span was created, and the mirror must say so rather than " +
            "count an event it never actually emitted");
        measurements.Single().Result.Should().Be("not_recorded");
    }

    [Fact]
    public void Emit_ReportsRecorded_WhenTheSpanIsActuallyCreated()
    {
        var eventId = Guid.NewGuid();
        using var listener = ListenToGatewaySpans(eventId, out var spans);
        using var measurements = new EmittedEventRecorder();

        var recorded = SanitizedTelemetryEmitter.EmitAzureMonitorMirror(
            Guid.NewGuid(),
            eventId,
            "interaction",
            "chat",
            DateTime.UtcNow.AddMinutes(-5),
            DateTime.UtcNow.AddMinutes(-4));

        recorded.Should().BeTrue();
        spans.Should().HaveCount(1);
        measurements.Single().Result.Should().Be("recorded");
        measurements.Single().RecordType.Should().Be("interaction");
        measurements.Single().Operation.Should().Be("chat");
    }

    [Fact]
    public void Emit_StartsTheMirrorAsARootSpan_SoItIsNeverNestedOutsideItsParentsLifetime()
    {
        var eventId = Guid.NewGuid();
        using var listener = ListenToGatewaySpans(eventId, out var spans);
        using var ambientSource = new ActivitySource("Gateway.Tests.Ambient");
        using var ambientListener = new ActivityListener
        {
            ShouldListenTo = source => source.Name == "Gateway.Tests.Ambient",
            Sample = (ref ActivityCreationOptions<ActivityContext> _) =>
                ActivitySamplingResult.AllDataAndRecorded
        };
        ActivitySource.AddActivityListener(ambientListener);

        using var ambient = ambientSource.StartActivity("worker.process_message");
        ambient.Should().NotBeNull();

        // The mirror carries the original event's timestamps, which routinely predate the
        // worker run that processes the message. Nesting it under the processing span would
        // produce a child whose lifetime falls outside its parent's.
        SanitizedTelemetryEmitter.EmitAzureMonitorMirror(
            Guid.NewGuid(),
            eventId,
            "activity",
            "execute_tool",
            DateTime.UtcNow.AddHours(-3),
            DateTime.UtcNow.AddHours(-3).AddSeconds(2));

        var mirror = spans.Should().ContainSingle().Subject;
        mirror.ParentId.Should().BeNull();
        mirror.TraceId.Should().NotBe(ambient!.TraceId);
        mirror.GetTagItem("gateway.correlation.trace_id")
            .Should().Be(ambient.TraceId.ToHexString(),
                "rooting the mirror must not cost the correlation back to the processing span");
        Activity.Current.Should().BeSameAs(
            ambient,
            "the emitter must restore the ambient span it detached from");
    }

    [Fact]
    public void Emit_UsesTheOriginalEventTimestamps()
    {
        var eventId = Guid.NewGuid();
        using var listener = ListenToGatewaySpans(eventId, out var spans);
        var started = new DateTime(2026, 3, 1, 10, 0, 0, DateTimeKind.Utc);
        var ended = started.AddSeconds(3);

        SanitizedTelemetryEmitter.EmitAzureMonitorMirror(
            Guid.NewGuid(),
            eventId,
            "activity",
            "output_messages",
            started,
            ended);

        var mirror = spans.Should().ContainSingle().Subject;
        mirror.StartTimeUtc.Should().Be(started);
        mirror.Duration.Should().Be(ended - started);
    }

    // Collects only the spans carrying this test's event id. The listener is registered
    // process-wide and can never be unregistered, so an unfiltered collector would also
    // capture gateway spans produced by anything else running in the same process.
    private static ActivityListener ListenToGatewaySpans(Guid eventId, out List<Activity> spans)
    {
        var recorded = new List<Activity>();
        spans = recorded;
        var expected = eventId.ToString("D");
        var listener = new ActivityListener
        {
            ShouldListenTo = source => source.Name == GatewayActivitySource.Name,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) =>
                ActivitySamplingResult.AllDataAndRecorded,
            ActivityStopped = activity =>
            {
                if (string.Equals(
                        activity.GetTagItem("gateway.event.id") as string,
                        expected,
                        StringComparison.Ordinal))
                {
                    recorded.Add(activity);
                }
            }
        };
        ActivitySource.AddActivityListener(listener);
        return listener;
    }

    private sealed record EmittedEvent(string RecordType, string Operation, string Result);

    private sealed class EmittedEventRecorder : IDisposable
    {
        private readonly MeterListener _listener;
        private readonly List<EmittedEvent> _events = [];
        private readonly Lock _gate = new();

        public EmittedEventRecorder()
        {
            _listener = new MeterListener
            {
                InstrumentPublished = (instrument, listener) =>
                {
                    if (instrument.Meter.Name == GatewayObservabilityMetrics.MeterName &&
                        instrument.Name == EmittedEventsInstrument)
                    {
                        listener.EnableMeasurementEvents(instrument);
                    }
                }
            };
            _listener.SetMeasurementEventCallback<long>(OnMeasurement);
            _listener.Start();
        }

        public EmittedEvent Single()
        {
            using (_gate.EnterScope())
            {
                _events.Should().HaveCount(1);
                return _events[0];
            }
        }

        private void OnMeasurement(
            Instrument instrument,
            long measurement,
            ReadOnlySpan<KeyValuePair<string, object?>> tags,
            object? state)
        {
            string? recordType = null;
            string? operation = null;
            string? result = null;
            foreach (var tag in tags)
            {
                switch (tag.Key)
                {
                    case "gateway.record.type":
                        recordType = tag.Value?.ToString();
                        break;
                    case "gateway.operation":
                        operation = tag.Value?.ToString();
                        break;
                    case "gateway.export.result":
                        result = tag.Value?.ToString();
                        break;
                }
            }

            using (_gate.EnterScope())
            {
                _events.Add(new EmittedEvent(
                    recordType ?? string.Empty,
                    operation ?? string.Empty,
                    result ?? string.Empty));
            }
        }

        public void Dispose() => _listener.Dispose();
    }
}
