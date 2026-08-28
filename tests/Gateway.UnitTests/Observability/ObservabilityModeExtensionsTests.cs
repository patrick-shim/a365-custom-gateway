using FluentAssertions;
using Gateway.Domain.Enums;

namespace Gateway.UnitTests.Observability;

public class ObservabilityModeExtensionsTests
{
    [Theory]
    [InlineData(ObservabilityMode.Disabled, false, false)]
    [InlineData(ObservabilityMode.GatewayOnly, false, true)]
    [InlineData(ObservabilityMode.Agent365, true, false)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, true, true)]
    public void Mapping_Should_RoundTrip_AllDestinationCombinations(
        ObservabilityMode mode,
        bool agent365Enabled,
        bool azureMonitorEnabled)
    {
        var destinations = mode.ToDestinations();

        destinations.Agent365ObservabilityEnabled.Should().Be(agent365Enabled);
        destinations.AzureMonitorExportEnabled.Should().Be(azureMonitorEnabled);
        ObservabilityModeExtensions.FromDestinations(agent365Enabled, azureMonitorEnabled)
            .Should().Be(mode);
    }

    [Fact]
    public void TryResolve_Should_UseAgent365Default_When_AllInputsAreOmitted()
    {
        var success = ObservabilityModeExtensions.TryResolve(
            legacyMode: null,
            agent365ObservabilityEnabled: null,
            azureMonitorExportEnabled: null,
            fallbackMode: ObservabilityMode.Agent365,
            out var mode);

        success.Should().BeTrue();
        mode.Should().Be(ObservabilityMode.Agent365);
    }

    [Fact]
    public void TryResolve_Should_CombineDestinationSpecificInputs()
    {
        var success = ObservabilityModeExtensions.TryResolve(
            legacyMode: null,
            agent365ObservabilityEnabled: true,
            azureMonitorExportEnabled: true,
            fallbackMode: ObservabilityMode.Agent365,
            out var mode);

        success.Should().BeTrue();
        mode.Should().Be(ObservabilityMode.Agent365AzureMonitor);
    }

    [Fact]
    public void TryResolve_Should_AcceptConsistentLegacyAndDestinationSpecificInputs()
    {
        var success = ObservabilityModeExtensions.TryResolve(
            legacyMode: nameof(ObservabilityMode.GatewayOnly),
            agent365ObservabilityEnabled: false,
            azureMonitorExportEnabled: true,
            fallbackMode: ObservabilityMode.Agent365,
            out var mode);

        success.Should().BeTrue();
        mode.Should().Be(ObservabilityMode.GatewayOnly);
    }

    [Fact]
    public void TryResolve_Should_RejectConflictingLegacyAndDestinationSpecificInputs()
    {
        var success = ObservabilityModeExtensions.TryResolve(
            legacyMode: nameof(ObservabilityMode.Agent365),
            agent365ObservabilityEnabled: true,
            azureMonitorExportEnabled: true,
            fallbackMode: ObservabilityMode.Agent365,
            out _);

        success.Should().BeFalse();
    }
}
