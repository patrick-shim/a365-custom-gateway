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

    [Theory]
    [InlineData("ProvisioningMode")]
    [InlineData("RetentionDaysActivityReceipts")]
    [InlineData("RetentionDaysAuditEvents")]
    [InlineData("RetentionDaysOutboxMessages")]
    [InlineData("ReconciliationEnabled")]
    [InlineData("ReconciliationIntervalHours")]
    [InlineData("StuckTransitionTimeoutDays")]
    [InlineData("UseGraphAgentRegistration")]
    [InlineData("UseCliProvisioningFallback")]
    public void Validate_Should_Reject_CompatibilityOnlyWrites(string property)
    {
        var command = property switch
        {
            "ProvisioningMode" => CreateCommand() with { ProvisioningMode = "Automatic" },
            "RetentionDaysActivityReceipts" => CreateCommand() with { RetentionDaysActivityReceipts = 30 },
            "RetentionDaysAuditEvents" => CreateCommand() with { RetentionDaysAuditEvents = 90 },
            "RetentionDaysOutboxMessages" => CreateCommand() with { RetentionDaysOutboxMessages = 14 },
            "ReconciliationEnabled" => CreateCommand() with { ReconciliationEnabled = true },
            "ReconciliationIntervalHours" => CreateCommand() with { ReconciliationIntervalHours = 24 },
            "StuckTransitionTimeoutDays" => CreateCommand() with { StuckTransitionTimeoutDays = 7 },
            "UseGraphAgentRegistration" => CreateCommand() with { UseGraphAgentRegistration = true },
            "UseCliProvisioningFallback" => CreateCommand() with { UseCliProvisioningFallback = true },
            _ => throw new ArgumentOutOfRangeException(nameof(property))
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error => error.PropertyName == property);
    }

    [Theory]
    [InlineData("RetentionDaysIdempotencyRecords", 0)]
    [InlineData("RetentionDaysIdempotencyRecords", 3_651)]
    [InlineData("RateLimitPerClient", 0)]
    [InlineData("RateLimitPerClient", 10_000_001)]
    [InlineData("RateLimitPerAgent", 0)]
    [InlineData("RateLimitPerAgent", 10_000_001)]
    [InlineData("RateLimitGlobal", 0)]
    [InlineData("RateLimitGlobal", 10_000_001)]
    public void Validate_Should_Reject_OutOfRangeImplementedNumericSettings(string property, int value)
    {
        var command = property switch
        {
            "RetentionDaysIdempotencyRecords" => CreateCommand() with { RetentionDaysIdempotencyRecords = value },
            "RateLimitPerClient" => CreateCommand() with { RateLimitPerClient = value },
            "RateLimitPerAgent" => CreateCommand() with { RateLimitPerAgent = value },
            "RateLimitGlobal" => CreateCommand() with { RateLimitGlobal = value },
            _ => throw new ArgumentOutOfRangeException(nameof(property))
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error => error.PropertyName == property);
    }
}
