using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Components;

public sealed class AgentDetailsPageTests : BunitContext
{
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();

    public AgentDetailsPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    [Theory]
    [InlineData(GatewayRoles.Administrator, true, true, true, true)]
    [InlineData(GatewayRoles.Operator, true, false, true, false)]
    [InlineData(GatewayRoles.Auditor, false, false, false, true)]
    [InlineData(GatewayRoles.SupportReader, false, false, false, false)]
    public void RoleCapabilities_ControlActionsAndRelatedData(
        string role,
        bool canOperate,
        bool isAdministrator,
        bool canViewProvisioning,
        bool canViewAudit)
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Portal user");
        auth.SetRoles(role);
        var agentId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(
                    agentId,
                    status: "Failed",
                    retryProvisioning: new ProvisioningRetryEligibilityDto(
                        true,
                        "The Gateway confirmed a retry-safe failure.")),
                "\"version-1\"",
                "detail-correlation"));
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(agentId, []));
        _api.GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>())
            .Returns(new AuditEventListResponse([], null));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));

        cut.WaitForAssertion(() =>
        {
            cut.Find("h1").TextContent.Should().Be("Role-aware agent");
            var buttonLabels = cut.FindAll("fluent-button")
                .Select(button => button.TextContent.Trim())
                .ToList();
            buttonLabels.Contains("Enable agent").Should().Be(canOperate);
            buttonLabels.Contains("Disable agent").Should().Be(canOperate);
            buttonLabels.Contains("Save features").Should().Be(isAdministrator);
            buttonLabels.Contains("Retry provisioning").Should().Be(isAdministrator);
            buttonLabels.Contains("Delete registration").Should().Be(isAdministrator);
            cut.FindAll("#history-heading").Any().Should().Be(canViewProvisioning);
            cut.FindAll("#audit-heading").Any().Should().Be(canViewAudit);
        });

        _api.Received(canViewProvisioning ? 1 : 0)
            .GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>());
        _api.Received(canViewAudit ? 1 : 0)
            .GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData("Failed", "Retry is unavailable while another provisioning operation is pending or running.")]
    [InlineData("Failed", "Retry is unavailable because this registration has non-replayable legacy provisioning history.")]
    [InlineData("Failed", "Retry is unavailable because the latest result is ambiguous. Reconcile Microsoft resource state manually.")]
    [InlineData("RequiresManualIntervention", "This registration requires manual intervention and must not be retried or replayed.")]
    public void UnsupportedRetryDecision_HidesRetryActionAndShowsServerReason(
        string status,
        string safeReason)
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(
                    agentId,
                    status: status,
                    retryProvisioning: new ProvisioningRetryEligibilityDto(false, safeReason)),
                "\"version-1\"",
                "detail-correlation"));
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(agentId, []));
        _api.GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>())
            .Returns(new AuditEventListResponse([], null));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("Provisioning retry unavailable");
            cut.Markup.Should().Contain(safeReason);
            cut.FindAll("fluent-button")
                .Should().NotContain(button => button.TextContent.Trim() == "Retry provisioning");
        });
        _ = _api.DidNotReceive().RetryProvisioningAsync(
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task RetrySafeDecision_ShowsActionAndSubmitsOneConfirmedRetry()
    {
        const string safeReason = "The Gateway confirmed that the latest workflow-v2 failure is safely retryable.";
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(
                    agentId,
                    status: "Failed",
                    retryProvisioning: new ProvisioningRetryEligibilityDto(true, safeReason)),
                "\"version-1\"",
                "detail-correlation"));
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(agentId, []));
        _api.GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>())
            .Returns(new AuditEventListResponse([], null));
        _api.RetryProvisioningAsync(
                agentId,
                Arg.Any<CancellationToken>())
            .Returns(new AsyncOperationResponse(agentId, "Provisioning", operationId, null));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));
        var retryButton = cut.WaitForElement("fluent-button");
        retryButton = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Retry provisioning");

        retryButton.HasAttribute("disabled").Should().BeFalse();
        cut.Markup.Should().Contain(safeReason);
        await retryButton.ClickAsync(new MouseEventArgs());
        cut.Find("#confirm-message").TextContent.Should().Contain("confirmed retry-safe failure");
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).RetryProvisioningAsync(
            agentId,
            Arg.Any<CancellationToken>());
        Services.GetRequiredService<NavigationManager>().Uri
            .Should().EndWith($"/operations/{operationId:D}");
    }

    [Theory]
    [InlineData("Disabled", "Disabled", "Disabled")]
    [InlineData("GatewayOnly", "Disabled", "Enabled")]
    [InlineData("Agent365", "Enabled", "Disabled")]
    [InlineData("Agent365AzureMonitor", "Enabled", "Enabled")]
    public void LegacyModes_RenderAsIndependentReadOnlyDestinations(
        string legacyMode,
        string expectedAgent365,
        string expectedAzureMonitor)
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Reader user");
        auth.SetRoles(GatewayRoles.SupportReader);
        var agentId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(
                    agentId,
                    features: new AgentFeaturesDto(legacyMode, false, null)),
                "\"version-1\"",
                "detail-correlation"));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));

        cut.WaitForAssertion(() =>
        {
            var items = cut.FindAll(".detail-item");
            items.Single(item => item.TextContent.Contains("Agent 365 observability"))
                .TextContent.Should().Contain(expectedAgent365);
            items.Single(item => item.TextContent.Contains("Azure Monitor activity mirror"))
                .TextContent.Should().Contain(expectedAzureMonitor);
        });
    }

    [Theory]
    [InlineData(true, false, "Agent365")]
    [InlineData(false, true, "GatewayOnly")]
    [InlineData(true, true, "Agent365AzureMonitor")]
    [InlineData(false, false, "Disabled")]
    public async Task SaveFeatures_MapsIndependentDestinationsToCanonicalAndLegacyValues(
        bool agent365Enabled,
        bool azureMonitorEnabled,
        string expectedLegacyMode)
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        var resource = new GatewayApiResource<AgentDetailDto>(
            CreateAgent(
                agentId,
                features: new AgentFeaturesDto("Agent365", false, null, true, false)),
            "\"version-1\"",
            "detail-correlation");
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>()).Returns(resource);
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(agentId, []));
        _api.GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>())
            .Returns(new AuditEventListResponse([], null));
        _api.UpdateAgentFeaturesAsync(
                agentId,
                Arg.Any<UpdateFeaturesRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new UpdateFeaturesResponse(
                agentId,
                new AgentFeaturesDto(
                    expectedLegacyMode,
                    false,
                    null,
                    agent365Enabled,
                    azureMonitorEnabled),
                DateTime.UtcNow));
        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));
        cut.WaitForElement("#feature-agent365-observability-enabled");
        cut.Find("#feature-agent365-observability-enabled").Change(agent365Enabled);
        cut.Find("#feature-azure-monitor-export-enabled").Change(azureMonitorEnabled);
        var saveButton = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Save features");

        await saveButton.ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).UpdateAgentFeaturesAsync(
            agentId,
            Arg.Is<UpdateFeaturesRequest>(request =>
                request.ObservabilityMode == expectedLegacyMode &&
                request.Agent365ObservabilityEnabled == agent365Enabled &&
                request.AzureMonitorExportEnabled == azureMonitorEnabled),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task DeleteConfirmation_SubmitsGatewayRegistrationDeletion()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(agentId),
                "\"version-1\"",
                "detail-correlation"));
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(agentId, []));
        _api.GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>())
            .Returns(new AuditEventListResponse([], null));
        _api.DeleteAgentAsync(
                agentId,
                Arg.Any<CancellationToken>())
            .Returns(new DeleteAgentResponse(
                agentId,
                "Deleting",
                operationId,
                Links: null));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));
        cut.WaitForElement("h1");
        var deleteButton = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Delete registration");

        await deleteButton.ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            cut.Find("#confirm-message").TextContent.Should().Contain("linked Microsoft resources are not changed");
            cut.Find(".confirm-extra").TextContent.Should().Contain("child Agent ID");
        });

        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).DeleteAgentAsync(
            agentId,
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void ProvisioningErrors_DoNotRenderRawWorkerExceptionText()
    {
        const string sensitiveWorkerMessage = "credential=sensitive-value; endpoint=https://internal.example";
        var auth = AddAuthorization();
        auth.SetAuthorized("Operator user");
        auth.SetRoles(GatewayRoles.Operator);
        var agentId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(
                    agentId,
                    new ProvisioningStatusDto("CreateResources", 45, sensitiveWorkerMessage)),
                "\"version-1\"",
                "detail-correlation"));
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(
                agentId,
                [
                    new ProvisioningJobDto(
                        Guid.NewGuid(),
                        "RegisterAgent",
                        "Failed",
                        45,
                        DateTime.UtcNow.AddMinutes(-2),
                        DateTime.UtcNow.AddMinutes(-1),
                        new OperationErrorDto("PROVISIONING_FAILED", sensitiveWorkerMessage),
                        Steps: [])
                ]));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("Review the provisioning history and secured worker logs");
            cut.Markup.Should().Contain("Diagnostic details are available only in secured worker logs");
            cut.Markup.Should().NotContain(sensitiveWorkerMessage);
        });
    }

    [Fact]
    public void AgentIdentityMapping_RendersIdentityIdsAndGatewayConnection()
    {
        const string agentIdentityClientId = "b7ca1bd0-9a5b-4be0-babc-ce2459f97364";
        const string agentIdentityObjectId = "12c02f9f-e188-4201-ab9d-e5b476fa8c92";
        const string blueprintClientId = "34ab15af-d8c5-485c-9a95-b53ea85247aa";
        const string blueprintObjectId = blueprintClientId;
        const string registryRecordId = "registry-preview-record";
        var auth = AddAuthorization();
        auth.SetAuthorized("Reader user");
        auth.SetRoles(GatewayRoles.SupportReader);
        var agentId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(
                    agentId,
                    agent365: new Agent365InfoDto(
                        agentIdentityClientId,
                        blueprintClientId,
                        registryRecordId,
                        agentIdentityObjectId,
                        blueprintObjectId),
                    status: "Active"),
                "\"version-1\"",
                "detail-correlation"));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));

        cut.WaitForAssertion(() =>
        {
            var details = cut.FindAll(".detail-item");
            details.Single(item => item.TextContent.Contains("Agent Identity client ID"))
                .TextContent.Should().Contain(agentIdentityClientId);
            details.Single(item => item.TextContent.Contains("Agent Identity object ID"))
                .TextContent.Should().Contain(agentIdentityObjectId);
            details.Single(item => item.TextContent.Contains("Blueprint client ID"))
                .TextContent.Should().Contain(blueprintClientId);
            details.Single(item => item.TextContent.Contains("Blueprint object ID"))
                .TextContent.Should().Contain(blueprintObjectId);
            cut.Find("section[aria-labelledby='agent365-heading']")
                .TextContent.Should().Contain("may contain the same GUID");
            details.Should().NotContain(item =>
                item.TextContent.Contains("External runtime managed-identity object ID"));

            var connection = cut.Find("section[aria-labelledby='gateway-connection-heading']");
            connection.TextContent.Should().Contain("Gateway connection");
            connection.TextContent.Should().Contain("role-aware-agent");
            connection.TextContent.Should().Contain("/api/v1/agent-activities");
            connection.TextContent.Should().Contain("/api/v1/ai-interactions");
            connection.TextContent.Should().Contain("Bearer Gateway credential");
            connection.TextContent.Should().Contain("binds that credential to this registration");
            connection.TextContent.Should().NotContain("ingestion remains unavailable");
        });
    }

    [Fact]
    public async Task Administrator_CanIssueAdditionalCredentialWithOneTimeHandoff()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        var existingKeyId = Guid.NewGuid();
        var issuedKeyId = Guid.NewGuid();
        const string oneTimeApiKey = "a365gw_v1_one-time-rotation-secret";
        ConfigureAdministratorLoads(
            agentId,
            new AgentIngressCredentialListResponse(
                agentId,
                [CreateCredentialMetadata(existingKeyId)]));
        _api.IssueAgentIngressCredentialAsync(
                agentId,
                Arg.Any<CancellationToken>())
            .Returns(new IssueAgentIngressCredentialResponse(
                agentId,
                "role-aware-agent",
                new AgentGatewayCredentialDto(
                    issuedKeyId,
                    oneTimeApiKey,
                    DateTime.UtcNow.AddDays(365))));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));
        var issueButton = cut.WaitForElement("fluent-button");
        issueButton = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Issue additional credential");

        await issueButton.ClickAsync(new MouseEventArgs());
        cut.Find("#confirm-message").TextContent.Should()
            .Contain("current credential remains valid");
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            cut.Find("#issued-gateway-api-key").GetAttribute("value")
                .Should().Be(oneTimeApiKey);
            cut.Find("#issued-gateway-authorization-header").GetAttribute("value")
                .Should().Be($"Bearer {oneTimeApiKey}");
            cut.Markup.Should().Contain("cannot be retrieved again");
        });
        _ = _api.Received(1).IssueAgentIngressCredentialAsync(
            agentId,
            Arg.Any<CancellationToken>());

        await cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "I saved this key")
            .ClickAsync(new MouseEventArgs());
        cut.FindAll("#issued-gateway-api-key").Should().BeEmpty();
        cut.Markup.Should().NotContain(oneTimeApiKey);
    }

    [Fact]
    public async Task Administrator_RevokeRequiresNamedConfirmationAndKeepsOverlapVisible()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        var firstKeyId = Guid.NewGuid();
        var secondKeyId = Guid.NewGuid();
        var metadata = new AgentIngressCredentialListResponse(
            agentId,
            [
                CreateCredentialMetadata(firstKeyId),
                CreateCredentialMetadata(secondKeyId)
            ]);
        ConfigureAdministratorLoads(agentId, metadata);
        _api.RevokeAgentIngressCredentialAsync(
                agentId,
                firstKeyId,
                Arg.Any<CancellationToken>())
            .Returns(new RevokeAgentIngressCredentialResponse(
                agentId,
                CreateCredentialMetadata(firstKeyId, DateTime.UtcNow),
                AlreadyRevoked: false));

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));
        cut.WaitForAssertion(() =>
            cut.FindAll("fluent-button")
                .Count(button => button.TextContent.Trim() == "Revoke")
                .Should().Be(2));

        await cut.FindAll("fluent-button")
            .First(button => button.TextContent.Trim() == "Revoke")
            .ClickAsync(new MouseEventArgs());
        cut.Find(".confirm-extra").TextContent.Should().Contain(firstKeyId.ToString());
        _ = _api.DidNotReceive().RevokeAgentIngressCredentialAsync(
            Arg.Any<Guid>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());

        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).RevokeAgentIngressCredentialAsync(
            agentId,
            firstKeyId,
            Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(GatewayRoles.Operator)]
    [InlineData(GatewayRoles.Auditor)]
    [InlineData(GatewayRoles.SupportReader)]
    public void NonAdministrator_NeverLoadsOrRendersCredentialManagement(string role)
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Reader user");
        auth.SetRoles(role);
        var agentId = Guid.NewGuid();
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(agentId),
                "\"version-1\"",
                "detail-correlation"));
        if (role == GatewayRoles.Operator)
        {
            _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
                .Returns(new ProvisioningHistoryResponse(agentId, []));
        }
        if (role == GatewayRoles.Auditor)
        {
            _api.GetAgentAuditEventsAsync(
                    agentId,
                    Arg.Any<AuditEventQuery>(),
                    Arg.Any<CancellationToken>())
                .Returns(new AuditEventListResponse([], null));
        }

        var cut = Render<AgentDetails>(parameters => parameters
            .Add(component => component.AgentId, agentId));

        cut.WaitForAssertion(() => cut.Find("h1").TextContent.Should().Be("Role-aware agent"));
        cut.FindAll("#gateway-credentials-heading").Should().BeEmpty();
        _ = _api.DidNotReceive().GetAgentIngressCredentialsAsync(
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    private void ConfigureAdministratorLoads(
        Guid agentId,
        AgentIngressCredentialListResponse credentials)
    {
        _api.GetAgentAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<AgentDetailDto>(
                CreateAgent(agentId, status: "Active"),
                "\"version-1\"",
                "detail-correlation"));
        _api.GetProvisioningHistoryAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(new ProvisioningHistoryResponse(agentId, []));
        _api.GetAgentAuditEventsAsync(
                agentId,
                Arg.Any<AuditEventQuery>(),
                Arg.Any<CancellationToken>())
            .Returns(new AuditEventListResponse([], null));
        _api.GetAgentIngressCredentialsAsync(agentId, Arg.Any<CancellationToken>())
            .Returns(credentials);
    }

    private static AgentIngressCredentialMetadataDto CreateCredentialMetadata(
        Guid keyId,
        DateTime? revokedAtUtc = null) => new(
            keyId,
            DateTime.UtcNow.AddDays(-1),
            DateTime.UtcNow.AddDays(364),
            revokedAtUtc);

    private static AgentDetailDto CreateAgent(
        Guid agentId,
        ProvisioningStatusDto? provisioning = null,
        AgentFeaturesDto? features = null,
        Agent365InfoDto? agent365 = null,
        string status = "Disabled",
        ProvisioningRetryEligibilityDto? retryProvisioning = null) => new(
        agentId,
        "role-aware-agent",
        "Role-aware agent",
        "Used to verify portal role capabilities.",
        status,
        "Development",
        Agent365: agent365,
        features ?? new AgentFeaturesDto("GatewayOnly", false, null),
        LastActivityAtUtc: null,
        CreatedAtUtc: DateTime.UtcNow.AddDays(-2),
        UpdatedAtUtc: DateTime.UtcNow.AddDays(-1),
        OwnerObjectId: "owner-object-id",
        Provisioning: provisioning,
        CreatedByObjectId: "creator-object-id",
        UpdatedByObjectId: "updater-object-id",
        RowVersion: [1, 2, 3],
        Links: null,
        RetryProvisioning: retryProvisioning);
}
