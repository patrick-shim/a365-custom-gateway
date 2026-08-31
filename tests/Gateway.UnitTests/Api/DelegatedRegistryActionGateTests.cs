using FluentAssertions;
using Gateway.Api.Options;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.Api;

public sealed class DelegatedRegistryActionGateTests
{
    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, true, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, true)]
    public void IsOpen_RequiresRegistryAndExplicitContinuousDevelopmentAccess(
        bool enabled,
        bool allowContinuousDevelopmentAccess,
        bool expected)
    {
        var gate = CreateGate(enabled, allowContinuousDevelopmentAccess);

        gate.IsOpen.Should().Be(expected);
    }

    [Fact]
    public void EnsureOpen_WhenFullyEnabled_AllowsTheAuthenticatedAction()
    {
        var gate = CreateGate(
            enabled: true,
            allowContinuousDevelopmentAccess: true);

        Action action = gate.EnsureOpen;

        action.Should().NotThrow();
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void EnsureOpen_WhenGateIsClosed_ThrowsSafeDomainError(
        bool enabled,
        bool allowContinuousDevelopmentAccess)
    {
        var gate = CreateGate(enabled, allowContinuousDevelopmentAccess);

        Action action = gate.EnsureOpen;

        action.Should()
            .Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
    }

    private static DelegatedRegistryActionGate CreateGate(
        bool enabled,
        bool allowContinuousDevelopmentAccess) =>
        new(
            Options.Create(new Agent365DelegatedRegistryOptions
            {
                Enabled = enabled,
                AllowContinuousDevelopmentAccess = allowContinuousDevelopmentAccess
            }));
}
