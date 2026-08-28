using FluentAssertions;
using Gateway.Api.Options;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.Api;

public sealed class DelegatedRegistryActionGateTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 8, 27, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void EnsureOpen_AllowsOnlyTheBoundOperationDuringItsOwnWindow()
    {
        var operationId = Guid.NewGuid();
        var gate = CreateGate(
            enabled: true,
            expiry: Now.AddMinutes(2).ToString("O"),
            operationId.ToString("D"));

        var matching = () => gate.EnsureOpen(operationId);
        var mismatched = () => gate.EnsureOpen(Guid.NewGuid());

        matching.Should().NotThrow();
        mismatched.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    [Theory]
    [InlineData(false, "2026-08-27T12:01:00Z")]
    [InlineData(true, null)]
    [InlineData(true, "not-a-timestamp")]
    [InlineData(true, "2026-08-27T12:00:00Z")]
    [InlineData(true, "2026-08-27T21:01:00+09:00")]
    public void EnsureOpen_WhenDisabledExpiredMalformedOrNonUtc_FailsClosed(
        bool enabled,
        string? expiry)
    {
        var operationId = Guid.NewGuid();
        var gate = CreateGate(enabled, expiry, operationId.ToString("D"));

        var action = () => gate.EnsureOpen(operationId);

        action.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    [Fact]
    public void ContinuousDevelopmentAccess_WhenEnabled_AllowsAnyOperationWithoutAWindow()
    {
        var gate = new DelegatedRegistryActionGate(
            Options.Create(new Agent365DelegatedRegistryOptions
            {
                Enabled = true,
                AllowContinuousDevelopmentAccess = true,
                RequireExactActionBinding = true
            }),
            new FixedTimeProvider());

        var action = () => gate.EnsureOpen(Guid.NewGuid());

        action.Should().NotThrow();
    }

    [Fact]
    public void ContinuousDevelopmentAccess_WhenDisabled_RemainsClosed()
    {
        var gate = new DelegatedRegistryActionGate(
            Options.Create(new Agent365DelegatedRegistryOptions
            {
                Enabled = false,
                AllowContinuousDevelopmentAccess = true,
                RequireExactActionBinding = true
            }),
            new FixedTimeProvider());

        var action = () => gate.EnsureOpen(Guid.NewGuid());

        action.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    private static DelegatedRegistryActionGate CreateGate(
        bool enabled,
        string? expiry,
        string? authorizedOperationId) =>
        new(
            Options.Create(new Agent365DelegatedRegistryOptions
            {
                Enabled = enabled,
                RequireExactActionBinding = true,
                ActionExpiresAtUtc = expiry,
                AuthorizedOperationId = authorizedOperationId
            }),
            new FixedTimeProvider());

    private sealed class FixedTimeProvider : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
