using FluentAssertions;
using Gateway.Application.Configuration.Commands;
using Gateway.Application.Configuration.Validators;

namespace Gateway.UnitTests.Validators;

public class UpdateSystemConfigValidatorTests
{
    private readonly UpdateSystemConfigValidator _validator = new();

    private static UpdateSystemConfigCommand CreateCommand() =>
        new(
            ProvisioningMode: null,
            DefaultObservabilityMode: null,
            DefaultPurviewEnabled: null,
            DefaultPurviewMode: null,
            RetentionDaysActivityReceipts: null,
            RetentionDaysAuditEvents: null,
            RetentionDaysIdempotencyRecords: null,
            RetentionDaysOutboxMessages: null,
            RateLimitPerClient: null,
            RateLimitPerAgent: null,
            RateLimitGlobal: null,
            ReconciliationEnabled: null,
            ReconciliationIntervalHours: null,
            StuckTransitionTimeoutDays: null,
            UseGraphAgentRegistration: null,
            UseCliProvisioningFallback: null,
            CallerObjectId: "caller-oid-001");

    [Fact]
    public void Validate_Should_Pass_When_OnlyDestinationSpecificSettingsAreProvided()
    {
        var command = CreateCommand() with
        {
            DefaultAgent365ObservabilityEnabled = true,
            DefaultAzureMonitorExportEnabled = false
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_LegacyAndDestinationSpecificSettingsAgree()
    {
        var command = CreateCommand() with
        {
            DefaultObservabilityMode = "Agent365AzureMonitor",
            DefaultAgent365ObservabilityEnabled = true,
            DefaultAzureMonitorExportEnabled = true
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_LegacyAndDestinationSpecificSettingsConflict()
    {
        var command = CreateCommand() with
        {
            DefaultObservabilityMode = "GatewayOnly",
            DefaultAgent365ObservabilityEnabled = true
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "DefaultObservabilityMode");
    }

    [Fact]
    public void Validate_Should_Fail_When_LegacyModeIsInvalid()
    {
        var command = CreateCommand() with { DefaultObservabilityMode = "InvalidMode" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "DefaultObservabilityMode");
    }
}
