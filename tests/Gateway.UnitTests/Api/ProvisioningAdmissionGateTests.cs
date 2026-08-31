using FluentAssertions;
using Gateway.Api.Options;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.Api;

public sealed class ProvisioningAdmissionGateTests
{
    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, true, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, true)]
    public void IsOpen_RequiresExecutionAndExplicitContinuousDevelopmentAccess(
        bool executionEnabled,
        bool allowContinuousDevelopmentAccess,
        bool expected)
    {
        var gate = CreateGate(executionEnabled, allowContinuousDevelopmentAccess);

        gate.IsOpen.Should().Be(expected);
        gate.IsRegistrationOpen.Should().Be(expected);
    }

    [Fact]
    public void ContinuousDevelopmentAccess_WhenFullyEnabled_AllowsRegistrationAndRetry()
    {
        var gate = CreateGate(
            executionEnabled: true,
            allowContinuousDevelopmentAccess: true);

        Action registration = gate.EnsureRegistrationOpen;
        Action retry = gate.EnsureRetryOpen;

        registration.Should().NotThrow();
        retry.Should().NotThrow();
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void EnsureRegistrationOpen_WhenGateIsClosed_ThrowsSafeDomainError(
        bool executionEnabled,
        bool allowContinuousDevelopmentAccess)
    {
        var gate = CreateGate(executionEnabled, allowContinuousDevelopmentAccess);

        Action action = gate.EnsureRegistrationOpen;

        action.Should()
            .Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void EnsureRetryOpen_WhenGateIsClosed_ThrowsSafeDomainError(
        bool executionEnabled,
        bool allowContinuousDevelopmentAccess)
    {
        var gate = CreateGate(executionEnabled, allowContinuousDevelopmentAccess);

        Action action = gate.EnsureRetryOpen;

        action.Should()
            .Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    private static ProvisioningAdmissionGate CreateGate(
        bool executionEnabled,
        bool allowContinuousDevelopmentAccess) =>
        new(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = executionEnabled,
                AllowContinuousDevelopmentAccess = allowContinuousDevelopmentAccess
            }));
}
