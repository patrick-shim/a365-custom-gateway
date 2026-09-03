namespace Gateway.ObservabilityRuntime.Tests;

/// <summary>
/// Serializes the test classes that observe process-global telemetry state.
/// <see cref="System.Diagnostics.ActivitySource"/> listeners and
/// <see cref="System.Diagnostics.Metrics.MeterListener"/> instances are registered
/// process-wide, not per test, so a class that asserts "no span was recorded" or
/// "exactly one measurement was taken" is wrong whenever another class is emitting
/// gateway telemetry at the same moment. xUnit runs each class as its own collection
/// by default, so without this the assertions pass or fail on scheduling luck.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class TelemetryCollection
{
    public const string Name = "GatewayTelemetry";
}
