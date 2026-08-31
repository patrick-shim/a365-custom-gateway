using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Configuration;
using Gateway.Application.Configuration.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class UpdateSystemConfigHandlerTests
{
    private readonly ISystemConfigurationRepository _configRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IUnitOfWork _unitOfWork;
    private readonly UpdateSystemConfigHandler _handler;

    public UpdateSystemConfigHandlerTests()
    {
        _configRepository = Substitute.For<ISystemConfigurationRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _purviewPolicyClient = Substitute.For<IPurviewPolicyClient>();
        _purviewPolicyClient.IsEnabled.Returns(true);
        _promptShieldClient = Substitute.For<IPromptShieldClient>();
        _promptShieldClient.IsEnabled.Returns(true);
        _unitOfWork = Substitute.For<IUnitOfWork>();
        _handler = new UpdateSystemConfigHandler(
            _configRepository,
            _auditEventRepository,
            _purviewPolicyClient,
            _promptShieldClient,
            _unitOfWork);
    }

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
    public async Task Handle_Should_MergePartialDestinationUpdateWithStoredMode()
    {
        var config = new SystemConfiguration
        {
            DefaultObservabilityMode = "GatewayOnly"
        };
        _configRepository.GetAsync(Arg.Any<CancellationToken>()).Returns(config);
        var command = CreateCommand() with { DefaultAgent365ObservabilityEnabled = true };

        var result = await _handler.Handle(command, CancellationToken.None);

        config.DefaultObservabilityMode.Should().Be("Agent365AzureMonitor");
        result.DefaultObservabilityMode.Should().Be("Agent365AzureMonitor");
        result.DefaultAgent365ObservabilityEnabled.Should().BeTrue();
        result.DefaultAzureMonitorExportEnabled.Should().BeTrue();
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData("Disabled", false, false)]
    [InlineData("GatewayOnly", false, true)]
    [InlineData("Agent365", true, false)]
    [InlineData("Agent365AzureMonitor", true, true)]
    public void Mapper_Should_ExposeCanonicalDestinations(
        string mode,
        bool agent365Enabled,
        bool azureMonitorEnabled)
    {
        var config = new SystemConfiguration { DefaultObservabilityMode = mode };

        var result = SystemConfigMapper.ToDto(config);

        result.DefaultObservabilityMode.Should().Be(mode);
        result.DefaultAgent365ObservabilityEnabled.Should().Be(agent365Enabled);
        result.DefaultAzureMonitorExportEnabled.Should().Be(azureMonitorEnabled);
    }

    [Fact]
    public void Contract_Should_KeepNewDestinationFieldsNull_When_LegacyPayloadOmitsThem()
    {
        const string legacyPayload = """
            {
              "provisioningMode": "Automatic",
              "defaultObservabilityMode": "Agent365",
              "defaultPurviewEnabled": false,
              "defaultPurviewMode": null,
              "retentionDaysActivityReceipts": 90,
              "retentionDaysAuditEvents": 365,
              "retentionDaysIdempotencyRecords": 7,
              "retentionDaysOutboxMessages": 30,
              "rateLimitPerClient": 100,
              "rateLimitPerAgent": 1000,
              "rateLimitGlobal": 10000,
              "reconciliationEnabled": true,
              "reconciliationIntervalHours": 24,
              "stuckTransitionTimeoutDays": 7,
              "useGraphAgentRegistration": false,
              "useCliProvisioningFallback": false
            }
            """;

        var result = JsonSerializer.Deserialize<SystemConfigDto>(
            legacyPayload,
            JsonSerializerOptions.Web);

        result.Should().NotBeNull();
        result!.DefaultAgent365ObservabilityEnabled.Should().BeNull();
        result.DefaultAzureMonitorExportEnabled.Should().BeNull();
    }

    [Fact]
    public async Task Handle_ShouldRejectPurviewDefault_WhenAdapterIsDisabled()
    {
        var config = new SystemConfiguration { DefaultPurviewEnabled = false };
        _configRepository.GetAsync(Arg.Any<CancellationToken>()).Returns(config);
        _purviewPolicyClient.IsEnabled.Returns(false);
        var command = CreateCommand() with
        {
            DefaultPurviewEnabled = true,
            DefaultPurviewMode = "AuditOnly"
        };

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        config.DefaultPurviewEnabled.Should().BeFalse();
        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_PreserveCompatibilityOnlyValues_WhenValidationIsBypassed()
    {
        var config = new SystemConfiguration
        {
            ProvisioningMode = "Automatic",
            DefaultObservabilityMode = "Agent365",
            RetentionDaysActivityReceipts = 90,
            RetentionDaysAuditEvents = 365,
            RetentionDaysIdempotencyRecords = 7,
            RetentionDaysOutboxMessages = 30,
            RateLimitPerClient = 100,
            RateLimitPerAgent = 1_000,
            RateLimitGlobal = 10_000,
            ReconciliationEnabled = true,
            ReconciliationIntervalHours = 24,
            StuckTransitionTimeoutDays = 7,
            UseGraphAgentRegistration = false,
            UseCliProvisioningFallback = false
        };
        _configRepository.GetAsync(Arg.Any<CancellationToken>()).Returns(config);
        var command = CreateCommand() with
        {
            ProvisioningMode = "Manual",
            RetentionDaysActivityReceipts = 1,
            RetentionDaysAuditEvents = 1,
            RetentionDaysIdempotencyRecords = 14,
            RetentionDaysOutboxMessages = 1,
            RateLimitPerClient = 200,
            RateLimitPerAgent = 2_000,
            RateLimitGlobal = 20_000,
            ReconciliationEnabled = false,
            ReconciliationIntervalHours = 1,
            StuckTransitionTimeoutDays = 1,
            UseGraphAgentRegistration = true,
            UseCliProvisioningFallback = true
        };

        var result = await _handler.Handle(command, CancellationToken.None);

        config.ProvisioningMode.Should().Be("Automatic");
        config.RetentionDaysActivityReceipts.Should().Be(90);
        config.RetentionDaysAuditEvents.Should().Be(365);
        config.RetentionDaysIdempotencyRecords.Should().Be(14);
        config.RetentionDaysOutboxMessages.Should().Be(30);
        config.RateLimitPerClient.Should().Be(200);
        config.RateLimitPerAgent.Should().Be(2_000);
        config.RateLimitGlobal.Should().Be(20_000);
        config.ReconciliationEnabled.Should().BeTrue();
        config.ReconciliationIntervalHours.Should().Be(24);
        config.StuckTransitionTimeoutDays.Should().Be(7);
        config.UseGraphAgentRegistration.Should().BeFalse();
        config.UseCliProvisioningFallback.Should().BeFalse();
        result.ProvisioningMode.Should().Be("Automatic");
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_RejectMergedRateLimits_WhenGlobalWouldBeLowerThanScopedLimit()
    {
        var config = new SystemConfiguration
        {
            DefaultObservabilityMode = "Agent365",
            RateLimitPerClient = 100,
            RateLimitPerAgent = 1_000,
            RateLimitGlobal = 10_000
        };
        _configRepository.GetAsync(Arg.Any<CancellationToken>()).Returns(config);
        var command = CreateCommand() with { RateLimitGlobal = 500 };

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ValidationException>();
        exception.Which.Errors.Should().ContainKey("RateLimitGlobal");
        config.RateLimitGlobal.Should().Be(10_000);
        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }
}
