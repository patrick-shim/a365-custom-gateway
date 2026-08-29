using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Components;

public sealed class SetupCenterPageTests : BunitContext
{
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();

    public SetupCenterPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;

        _api.GetHealthAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayHealthStatus("Healthy"));
        _api.GetReadinessAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayHealthStatus("Healthy"));
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var query = call.Arg<AgentListQuery>();
                return query.Status == "Active"
                    ? new AgentListResponse([], null, 0)
                    : new AgentListResponse([], null, 0);
            });
    }

    [Fact]
    public void Administrator_SeesServerCapabilitiesAndRegistrationAction()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(provisioningEnabled: true));

        var cut = Render<SetupCenter>();

        cut.WaitForAssertion(() =>
        {
            cut.Find("h1").TextContent.Should().Be("Setup center");
            cut.Markup.Should().Contain("InfrastructureReady");
            cut.Markup.Should().Contain("ControlPlaneReady");
            cut.Markup.Should().Contain("ProvisioningReady");
            cut.Markup.Should().Contain("FirstAgentActive");
            cut.Markup.Should().Contain("CanaryProven");
            cut.Markup.Should().Contain("Admission open");
            cut.FindAll("[href='/agents/register']").Should().NotBeEmpty();
        });

        _api.Received(1).GetSystemConfigAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public void NonAdministrator_DoesNotRequestAdministratorConfiguration()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Support user");
        auth.SetRoles(GatewayRoles.SupportReader);

        var cut = Render<SetupCenter>();

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("Role restricted");
            cut.Markup.Should().Contain("System capability details are restricted");
            cut.FindAll("[href='/agents/register']").Should().BeEmpty();
        });

        _api.DidNotReceive().GetSystemConfigAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public void ActiveGatewayRow_NeverPromotesCanaryToProven()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Operator user");
        auth.SetRoles(GatewayRoles.Operator);
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var query = call.Arg<AgentListQuery>();
                return query.Status == "Active"
                    ? new AgentListResponse([CreateAgent("Active")], null, 1)
                    : new AgentListResponse([CreateAgent("Active")], null, 1);
            });

        var cut = Render<SetupCenter>();

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("Gateway reported");
            var canaryCard = cut.FindAll(".readiness-card")
                .Single(element => element.TextContent.Contains("CanaryProven", StringComparison.Ordinal));
            canaryCard.QuerySelector(".readiness-state")!.TextContent.Should().Be("Not reported");
            canaryCard.TextContent.Should().Contain("not promoted to canary proof");
        });
    }

    [Fact]
    public void PartialFailure_PreservesAvailableEvidenceAndSafeCorrelation()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        _api.GetReadinessAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromException<GatewayHealthStatus>(new GatewayApiException(
                System.Net.HttpStatusCode.ServiceUnavailable,
                "The readiness check is unavailable.",
                "Retry after the dependency recovers.",
                null,
                null,
                "READINESS_UNAVAILABLE",
                "setup-safe-correlation",
                new Dictionary<string, string[]>(),
                null)));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(provisioningEnabled: false));

        var cut = Render<SetupCenter>();

        cut.WaitForAssertion(() =>
        {
            var alert = cut.Find("[role='alert']");
            alert.TextContent.Should().Contain("setup-safe-correlation");
            cut.Markup.Should().Contain("API liveness: Healthy");
            cut.Markup.Should().Contain("database readiness: not available");
        });
    }

    private static AgentSummaryDto CreateAgent(string status) => new(
        Guid.NewGuid(),
        "agent-setup-test",
        "Setup test agent",
        null,
        status,
        "Development",
        null,
        new AgentFeaturesDto("Agent365", false, null, true, false),
        null,
        DateTime.UtcNow.AddMinutes(-2),
        DateTime.UtcNow.AddMinutes(-1));

    private static SystemConfigDto CreateConfig(bool provisioningEnabled) => new(
        ProvisioningMode: "Automatic",
        DefaultObservabilityMode: "Agent365",
        DefaultPurviewEnabled: false,
        DefaultPurviewMode: "AuditOnly",
        RetentionDaysActivityReceipts: 30,
        RetentionDaysAuditEvents: 90,
        RetentionDaysIdempotencyRecords: 7,
        RetentionDaysOutboxMessages: 14,
        RateLimitPerClient: 100,
        RateLimitPerAgent: 200,
        RateLimitGlobal: 1_000,
        ReconciliationEnabled: false,
        ReconciliationIntervalHours: 24,
        StuckTransitionTimeoutDays: 7,
        UseGraphAgentRegistration: false,
        UseCliProvisioningFallback: false,
        DefaultAgent365ObservabilityEnabled: true,
        DefaultAzureMonitorExportEnabled: false,
        ProvisioningExecutionEnabled: provisioningEnabled,
        PurviewPolicyProvisioningEnabled: false,
        DefaultPromptShieldEnabled: false,
        PromptShieldAvailable: false);
}
