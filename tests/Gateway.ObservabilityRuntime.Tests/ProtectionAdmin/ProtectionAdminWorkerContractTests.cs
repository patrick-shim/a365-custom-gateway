using FluentAssertions;
using Gateway.Contracts.Messages;
using Gateway.Provisioning.Worker;

namespace Gateway.ObservabilityRuntime.Tests.ProtectionAdmin;

public sealed class ProtectionAdminWorkerContractTests
{
    [Fact]
    public void HostedProcessor_IsPinnedToDedicatedVersionedQueue()
    {
        ProtectionAdminWorkerService.QueueName.Should()
            .Be(ProtectionAdminQueueContract.QueueName);
        ProtectionAdminWorkerService.QueueName.Should()
            .Be("gateway-protection-admin-v1");
        typeof(ProtectionAdminWorkerOptions)
            .GetProperty("QueueName")
            .Should()
            .BeNull("the protection queue must not be redirected by configuration");
    }

    [Theory]
    [InlineData(9, 10, false)]
    [InlineData(10, 10, true)]
    public void FinalDelivery_UsesDedicatedWorkerThreshold(
        int deliveryCount,
        int maxDeliveryCount,
        bool expected)
    {
        ProtectionAdminWorkerService.IsFinalDelivery(deliveryCount, maxDeliveryCount)
            .Should()
            .Be(expected);
    }

    [Fact]
    public void ProcessingGate_DoesNotChangeRegistrationWorkerOptions()
    {
        ProtectionAdminWorkerService.ShouldStartProcessing(
                new ProtectionAdminWorkerOptions { ProcessingEnabled = false })
            .Should()
            .BeFalse();
        ProtectionAdminWorkerService.ShouldStartProcessing(
                new ProtectionAdminWorkerOptions())
            .Should()
            .BeFalse("optional protection administration must not close core registration");
        new ProvisioningWorkerOptions().QueueName.Should().Be("gateway-provisioning-v3");
    }
}
