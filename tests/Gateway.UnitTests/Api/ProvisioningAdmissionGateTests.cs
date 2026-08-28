using FluentAssertions;
using Gateway.Api.Options;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.Api;

public sealed class ProvisioningAdmissionGateTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 8, 25, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(false, null)]
    [InlineData(false, "not-a-timestamp")]
    [InlineData(false, "2026-08-25T12:01:00Z")]
    [InlineData(true, null)]
    [InlineData(true, "")]
    [InlineData(true, "not-a-timestamp")]
    [InlineData(true, "2026-08-25T21:01:00+09:00")]
    [InlineData(true, "2026-08-25T11:59:59Z")]
    [InlineData(true, "2026-08-25T12:00:00Z")]
    public void IsOpen_WhenConfigurationIsDisabledInvalidNonUtcOrNotFuture_ReturnsFalse(
        bool executionEnabled,
        string? admissionExpiresAtUtc)
    {
        var gate = CreateGate(executionEnabled, admissionExpiresAtUtc);

        gate.IsOpen.Should().BeFalse();
    }

    [Theory]
    [InlineData("2026-08-25T12:00:00.0000001Z")]
    [InlineData("2026-08-25T12:01:00+00:00")]
    [InlineData("2026-08-25T12:01:00+0000")]
    [InlineData("2026-08-25T12:01:00+00")]
    public void IsOpen_WhenEnabledWithValidFutureUtcExpiry_ReturnsTrue(
        string admissionExpiresAtUtc)
    {
        var gate = CreateGate(executionEnabled: true, admissionExpiresAtUtc);

        gate.IsOpen.Should().BeTrue();
    }

    [Fact]
    public void EnsureOpen_WhenGateIsClosed_ThrowsExistingSafeDomainError()
    {
        var gate = CreateGate(
            executionEnabled: true,
            admissionExpiresAtUtc: Now.ToString("O"));

        var action = () => gate.EnsureRegistrationOpen("agent-test");

        action.Should()
            .Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    [Fact]
    public void IsOpen_WhenTheConfiguredWindowExpires_ClosesWithoutAConfigurationReload()
    {
        var timeProvider = new MutableTimeProvider(Now);
        var gate = new ProvisioningAdmissionGate(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = true,
                RequireExactAdmissionBinding = false,
                AdmissionExpiresAtUtc = Now.AddMinutes(1).ToString("O")
            }),
            timeProvider);

        gate.IsOpen.Should().BeTrue();

        timeProvider.UtcNow = Now.AddMinutes(1);

        gate.IsOpen.Should().BeFalse();
    }

    [Fact]
    public void ContinuousDevelopmentAccess_WhenExecutionIsEnabled_DoesNotRequireExpiryOrBinding()
    {
        var gate = new ProvisioningAdmissionGate(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = true,
                AllowContinuousDevelopmentAccess = true,
                RequireExactAdmissionBinding = true
            }),
            new FixedTimeProvider(Now));

        var registration = () => gate.EnsureRegistrationOpen("agent-any");
        var retry = () => gate.EnsureRetryOpen(Guid.NewGuid());

        gate.IsOpen.Should().BeTrue();
        registration.Should().NotThrow();
        retry.Should().NotThrow();
    }

    [Fact]
    public void ContinuousDevelopmentAccess_WhenExecutionIsDisabled_RemainsClosed()
    {
        var gate = new ProvisioningAdmissionGate(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = false,
                AllowContinuousDevelopmentAccess = true,
                RequireExactAdmissionBinding = true
            }),
            new FixedTimeProvider(Now));

        gate.IsOpen.Should().BeFalse();
    }

    private static ProvisioningAdmissionGate CreateGate(
        bool executionEnabled,
        string? admissionExpiresAtUtc) =>
        new(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = executionEnabled,
                RequireExactAdmissionBinding = false,
                AdmissionExpiresAtUtc = admissionExpiresAtUtc
            }),
            new FixedTimeProvider(Now));

    [Fact]
    public void EnsureRegistrationOpen_WhenExactBindingMatches_AllowsOnlyThatExternalId()
    {
        var gate = new ProvisioningAdmissionGate(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = true,
                RequireExactAdmissionBinding = true,
                AdmissionExpiresAtUtc = Now.AddMinutes(1).ToString("O"),
                AuthorizedExternalAgentId = "agent-authorized"
            }),
            new FixedTimeProvider(Now));

        var matching = () => gate.EnsureRegistrationOpen("agent-authorized");
        var mismatched = () => gate.EnsureRegistrationOpen("agent-other");

        matching.Should().NotThrow();
        mismatched.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    [Fact]
    public void EnsureRetryOpen_WhenExactRetryBindingIsMissing_FailsClosed()
    {
        var gate = new ProvisioningAdmissionGate(
            Options.Create(new ProvisioningOptions
            {
                ExecutionEnabled = true,
                RequireExactAdmissionBinding = true,
                AdmissionExpiresAtUtc = Now.AddMinutes(1).ToString("O"),
                AuthorizedExternalAgentId = "agent-authorized"
            }),
            new FixedTimeProvider(Now));

        var action = () => gate.EnsureRetryOpen(Guid.NewGuid());

        action.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    private sealed class FixedTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => utcNow;
    }

    private sealed class MutableTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        public DateTimeOffset UtcNow { get; set; } = utcNow;

        public override DateTimeOffset GetUtcNow() => UtcNow;
    }
}
