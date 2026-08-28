using FluentAssertions;
using Gateway.Provisioning.Worker;

namespace Gateway.ObservabilityRuntime.Tests.Worker;

public sealed class ProvisioningWorkerServiceTests
{
    [Theory]
    [InlineData(9, 10, false)]
    [InlineData(10, 10, true)]
    [InlineData(11, 10, true)]
    public void IsFinalDelivery_UsesConfiguredQueueThreshold(
        int deliveryCount,
        int maxDeliveryCount,
        bool expected)
    {
        ProvisioningWorkerService.IsFinalDelivery(deliveryCount, maxDeliveryCount)
            .Should().Be(expected);
    }

    [Fact]
    public void ShouldStartProcessing_HonorsBootstrapGate()
    {
        ProvisioningWorkerService.ShouldStartProcessing(new ProvisioningWorkerOptions
        {
            ProcessingEnabled = false
        }).Should().BeFalse();

        ProvisioningWorkerService.ShouldStartProcessing(new ProvisioningWorkerOptions())
            .Should().BeTrue();
    }
}
