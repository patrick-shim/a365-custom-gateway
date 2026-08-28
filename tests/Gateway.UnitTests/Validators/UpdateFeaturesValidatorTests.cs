using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Validators;

namespace Gateway.UnitTests.Validators;

public class UpdateFeaturesValidatorTests
{
    private readonly UpdateFeaturesValidator _validator = new();

    private static UpdateFeaturesCommand CreateValidCommand() =>
        new(
            AgentId: Guid.NewGuid(),
            ObservabilityMode: "GatewayOnly",
            PurviewEnabled: true,
            PurviewMode: "AuditOnly",
            CallerObjectId: "caller-oid-001");

    [Fact]
    public void Validate_Should_Pass_When_CommandIsValid()
    {
        var command = CreateValidCommand();

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_ObservabilityModeIsNull()
    {
        var command = CreateValidCommand() with { ObservabilityMode = null };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_PurviewModeIsNull()
    {
        var command = CreateValidCommand() with { PurviewMode = null };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_BothModesAreNull()
    {
        var command = CreateValidCommand() with { ObservabilityMode = null, PurviewMode = null };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Theory]
    [InlineData("Disabled")]
    [InlineData("GatewayOnly")]
    [InlineData("Agent365")]
    [InlineData("Agent365AzureMonitor")]
    public void Validate_Should_Pass_When_ObservabilityModeIsValid(string mode)
    {
        var command = CreateValidCommand() with { ObservabilityMode = mode };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Theory]
    [InlineData("AuditOnly")]
    [InlineData("Enforce")]
    public void Validate_Should_Pass_When_PurviewModeIsValid(string mode)
    {
        var command = CreateValidCommand() with { PurviewMode = mode };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_ObservabilityModeIsInvalid()
    {
        var command = CreateValidCommand() with { ObservabilityMode = "InvalidMode" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ObservabilityMode");
    }

    [Fact]
    public void Validate_Should_Fail_When_PurviewModeIsInvalid()
    {
        var command = CreateValidCommand() with { PurviewMode = "InvalidMode" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "PurviewMode");
    }

    [Fact]
    public void Validate_Should_Pass_When_DestinationSpecificSettingsAreProvided()
    {
        var command = CreateValidCommand() with
        {
            ObservabilityMode = null,
            Agent365ObservabilityEnabled = true,
            AzureMonitorExportEnabled = true
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_LegacyAndDestinationSpecificSettingsAgree()
    {
        var command = CreateValidCommand() with
        {
            ObservabilityMode = "Agent365",
            Agent365ObservabilityEnabled = true,
            AzureMonitorExportEnabled = false
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_LegacyAndDestinationSpecificSettingsConflict()
    {
        var command = CreateValidCommand() with
        {
            ObservabilityMode = "Agent365",
            Agent365ObservabilityEnabled = true,
            AzureMonitorExportEnabled = true
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ObservabilityMode");
    }
}
