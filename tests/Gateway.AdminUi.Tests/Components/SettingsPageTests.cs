using System.Security.Claims;
using Bunit;
using Bunit.TestDoubles;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Forms;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Components;

public sealed class SettingsPageTests : BunitContext
{
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();
    private readonly BunitAuthorizationContext _authorization;

    public SettingsPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;

        _api.GetProtectionCapabilitiesAsync(Arg.Any<CancellationToken>())
            .Returns(Capabilities(
                ("Agent365RegistrationBeta", "Installed"),
                ("PromptShields", "Installed"),
                ("Purview", "Installed")));
        _api.GetPurviewTenantConnectionAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewTenantConnectionResponse>(
                new PurviewTenantConnectionResponse(null),
                null,
                "connection-correlation"));

        _authorization = AddAuthorization();
        _authorization.SetAuthorized("Admin user");
        _authorization.SetRoles(GatewayRoles.Administrator);
        _authorization.SetClaims(
            new Claim("tid", "7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747"),
            new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));
    }

    [Fact]
    public async Task ConfirmedSave_IsSentOnceWhileFirstUpdateIsPending()
    {
        var config = CreateConfig();
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(config);
        var completion = new TaskCompletionSource<SystemConfigDto>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _api.UpdateSystemConfigAsync(
                Arg.Any<UpdateSystemConfigRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(completion.Task);
        var cut = Render<Settings>();
        cut.WaitForElement("form");

        await cut.Find("form").SubmitAsync(EventArgs.Empty);
        var saveButton = cut.FindAll(".confirm-panel fluent-button").Last();

        var firstSave = saveButton.ClickAsync(new MouseEventArgs());
        cut.WaitForAssertion(() =>
        {
            _api.Received(1).UpdateSystemConfigAsync(
                Arg.Is<UpdateSystemConfigRequest>(request =>
                    request.ProvisioningMode == null &&
                    request.RateLimitGlobal == config.RateLimitGlobal &&
                    request.DefaultObservabilityMode == "Agent365" &&
                    request.DefaultAgent365ObservabilityEnabled == true &&
                    request.DefaultAzureMonitorExportEnabled == false &&
                    request.ReconciliationEnabled == null &&
                    request.ReconciliationIntervalHours == null &&
                    request.RetentionDaysActivityReceipts == null &&
                    request.RetentionDaysAuditEvents == null &&
                    request.RetentionDaysOutboxMessages == null &&
                    request.StuckTransitionTimeoutDays == null &&
                    request.UseGraphAgentRegistration == null &&
                    request.UseCliProvisioningFallback == null),
                Arg.Any<CancellationToken>());
            cut.Markup.Should().Contain("Working…");
        });

        var duplicateSave = saveButton.ClickAsync(new MouseEventArgs());
        await duplicateSave.WaitAsync(TimeSpan.FromSeconds(2));

        _ = _api.Received(1).UpdateSystemConfigAsync(
            Arg.Any<UpdateSystemConfigRequest>(),
            Arg.Any<CancellationToken>());

        completion.SetResult(config);
        await firstSave.WaitAsync(TimeSpan.FromSeconds(2));
        cut.WaitForAssertion(() =>
        {
            cut.Find(".success-banner").TextContent.Should().Contain("Settings saved.");
            cut.Find("fluent-dialog.confirm-dialog").HasAttribute("hidden").Should().BeTrue();
        });
    }

    [Fact]
    public async Task AmbiguousSettingsSave_RetriesTheExactSameIdempotentRequest()
    {
        var rowVersion = Convert.ToBase64String([1, 2, 3, 4, 5, 6, 7, 8]);
        var nextRowVersion = Convert.ToBase64String([2, 3, 4, 5, 6, 7, 8, 9]);
        var config = CreateConfig() with { RowVersion = rowVersion };
        var updated = config with { RowVersion = nextRowVersion };
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(config);
        var requests = new List<UpdateSystemConfigRequest>();
        _api.UpdateSystemConfigAsync(
                Arg.Any<UpdateSystemConfigRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                requests.Add(call.ArgAt<UpdateSystemConfigRequest>(0));
                return requests.Count == 1
                    ? Task.FromException<SystemConfigDto>(
                        new GatewayApiTransportException(
                            "The Gateway API request timed out.",
                            "save-correlation",
                            new TimeoutException()))
                    : Task.FromResult(updated);
            });
        var cut = Render<Settings>();
        cut.WaitForElement("form");

        await cut.Find("form").SubmitAsync(EventArgs.Empty);
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            cut.Find(".ambiguous-save-recovery").TextContent.Should()
                .Contain("save result is not yet known")
                .And.Contain("Retry the same protected request");
            cut.FindAll("fluent-button").Single(button =>
                button.TextContent.Contains("Review and save"))
                .HasAttribute("disabled").Should().BeTrue();
        });

        await cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains("Retry the same save"))
            .ClickAsync(new MouseEventArgs());

        requests.Should().HaveCount(2);
        requests[0].IdempotencyKey.Should().NotBeNull();
        requests[1].Should().Be(requests[0]);
        requests[1].IdempotencyKey.Should().Be(requests[0].IdempotencyKey);
        requests[1].ExpectedRowVersion.Should().Be(rowVersion);
        cut.FindAll(".ambiguous-save-recovery").Should().BeEmpty();
        cut.Find(".success-banner").TextContent.Should().Contain("Settings saved");
    }

    [Fact]
    public async Task AmbiguousSettingsSave_CanReloadServerTruthWithoutAnotherMutation()
    {
        var rowVersion = Convert.ToBase64String([1, 2, 3, 4, 5, 6, 7, 8]);
        var nextRowVersion = Convert.ToBase64String([2, 3, 4, 5, 6, 7, 8, 9]);
        var config = CreateConfig() with
        {
            RowVersion = rowVersion,
            RateLimitGlobal = 1_000
        };
        var recovered = config with
        {
            RowVersion = nextRowVersion,
            RateLimitGlobal = 2_000
        };
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(config, recovered);
        _api.UpdateSystemConfigAsync(
                Arg.Any<UpdateSystemConfigRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<SystemConfigDto>(
                new GatewayApiProtocolException(
                    "The Gateway response could not be verified.",
                    "save-correlation")));
        var cut = Render<Settings>();
        cut.WaitForElement("form");

        await cut.Find("form").SubmitAsync(EventArgs.Empty);
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());
        cut.WaitForElement(".ambiguous-save-recovery");

        await cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains("Reload current settings"))
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).UpdateSystemConfigAsync(
            Arg.Any<UpdateSystemConfigRequest>(),
            Arg.Any<CancellationToken>());
        _ = _api.Received(2).GetSystemConfigAsync(Arg.Any<CancellationToken>());
        cut.FindAll(".ambiguous-save-recovery").Should().BeEmpty();
        cut.Find("#limit-global").GetAttribute("value").Should().Be("2000");
    }

    [Theory]
    [InlineData("Disabled", false, false)]
    [InlineData("GatewayOnly", false, true)]
    [InlineData("Agent365", true, false)]
    [InlineData("Agent365AzureMonitor", true, true)]
    public void OmittedCanonicalDefaults_FallBackToLegacyMode(
        string legacyMode,
        bool expectedAgent365,
        bool expectedAzureMonitor)
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(legacyMode, agent365Enabled: null, azureMonitorEnabled: null));

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#default-agent365-observability-enabled").HasAttribute("checked")
            .Should().Be(expectedAgent365);
        cut.Find("#default-azure-monitor-export-enabled").HasAttribute("checked")
            .Should().Be(expectedAzureMonitor);
    }

    [Theory]
    [InlineData("Agent365AzureMonitor", false, false)]
    [InlineData("GatewayOnly", true, false)]
    [InlineData("Agent365", false, true)]
    [InlineData("Disabled", true, true)]
    public void CanonicalDefaults_WinOverConflictingLegacyMode(
        string legacyMode,
        bool agent365Enabled,
        bool azureMonitorEnabled)
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(legacyMode, agent365Enabled, azureMonitorEnabled));

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#default-agent365-observability-enabled").HasAttribute("checked")
            .Should().Be(agent365Enabled);
        cut.Find("#default-azure-monitor-export-enabled").HasAttribute("checked")
            .Should().Be(azureMonitorEnabled);
    }

    [Theory]
    [InlineData(true, false, "Agent365")]
    [InlineData(false, true, "GatewayOnly")]
    [InlineData(true, true, "Agent365AzureMonitor")]
    [InlineData(false, false, "Disabled")]
    public async Task Save_MapsIndependentDefaultsToCanonicalAndLegacyRequestValues(
        bool agent365Enabled,
        bool azureMonitorEnabled,
        string expectedLegacyMode)
    {
        var config = CreateConfig();
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(config);
        _api.UpdateSystemConfigAsync(
                Arg.Any<UpdateSystemConfigRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(CreateConfig(expectedLegacyMode, agent365Enabled, azureMonitorEnabled));
        var cut = Render<Settings>();
        cut.WaitForElement("form");
        cut.Find("#default-agent365-observability-enabled").Change(agent365Enabled);
        cut.Find("#default-azure-monitor-export-enabled").Change(azureMonitorEnabled);

        await cut.Find("form").SubmitAsync(EventArgs.Empty);
        await cut.FindAll(".confirm-panel fluent-button").Last().ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).UpdateSystemConfigAsync(
            Arg.Is<UpdateSystemConfigRequest>(request =>
                request.DefaultObservabilityMode == expectedLegacyMode &&
                request.DefaultAgent365ObservabilityEnabled == agent365Enabled &&
                request.DefaultAzureMonitorExportEnabled == azureMonitorEnabled),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void CompatibilityOnlySettings_AreNotEditable()
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Markup.Should().Contain("do not have a cleanup worker and are not editable");
        cut.Markup.Should().Contain("Registration defaults");
        cut.Markup.Should().NotContain("Provisioning mode");
        cut.Markup.Should().NotContain("id=\"provisioning-mode\"");
        cut.Markup.Should().NotContain("id=\"retention-receipts\"");
        cut.Markup.Should().NotContain("id=\"retention-audit\"");
        cut.Markup.Should().NotContain("id=\"retention-outbox\"");
        cut.Markup.Should().NotContain("id=\"transition-timeout\"");
        cut.Markup.Should().NotContain("id=\"reconciliation-enabled\"");
        cut.Markup.Should().NotContain("id=\"reconciliation-hours\"");
        cut.Markup.Should().NotContain("id=\"graph-registration\"");
        cut.Markup.Should().NotContain("id=\"cli-fallback\"");
    }

    [Fact]
    public void RateLimits_AreShownAsDistributedEnforcedAndEditable()
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#limits-heading").TextContent.Should().Contain("Requests per minute");
        cut.Markup.Should().Contain("enforces fixed one-minute limits in SQL");
        cut.Markup.Should().Contain("registration limits aggregate rotated keys");
        cut.Find("#limit-client").HasAttribute("disabled").Should().BeFalse();
        cut.Find("#limit-agent").HasAttribute("disabled").Should().BeFalse();
        cut.Find("#limit-global").HasAttribute("disabled").Should().BeFalse();
    }

    [Theory]
    [InlineData(GatewayRoles.Operator, "Operator", true)]
    [InlineData(GatewayRoles.Auditor, "Auditor", false)]
    [InlineData(GatewayRoles.SupportReader, "Support Reader", false)]
    public void NonAdministratorRoles_SeeSafeReadOnlyProtectionState(
        string role,
        string roleLabel,
        bool canReadGovernance)
    {
        _authorization.SetRoles(role);

        var cut = Render<Settings>();

        cut.WaitForAssertion(() =>
        {
            cut.Find(".role-notice").TextContent.Should().Contain(roleLabel);
            cut.Markup.Should().Contain("Protection capabilities");
            cut.Markup.Should().Contain("Deployment-wide preview boundary");
            cut.FindAll("form.settings-form").Should().BeEmpty();
            cut.FindAll("fluent-button").Should().NotContain(button =>
                button.TextContent.Contains("Review tenant connection"));
            cut.Markup.Contains("Governance details are restricted").Should()
                .Be(!canReadGovernance);
        });
        _api.DidNotReceive().GetSystemConfigAsync(Arg.Any<CancellationToken>());
        _api.Received(canReadGovernance ? 1 : 0)
            .GetPurviewTenantConnectionAsync(Arg.Any<CancellationToken>());
        _api.DidNotReceive()
            .GetPurviewSensitiveInformationTypesAsync(Arg.Any<CancellationToken>());
        if (!canReadGovernance)
        {
            _api.DidNotReceive()
                .GetPurviewKnowYourDataAsync(Arg.Any<CancellationToken>());
            _api.DidNotReceive()
                .GetPurviewDlpProfilesAsync(Arg.Any<CancellationToken>());
        }
    }

    [Fact]
    public void PurviewJourney_DistinguishesStatesAndKeepsScopesSeparate()
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var connectionId = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var sitId = Guid.NewGuid();
        ArrangeConnectedJourney(
            tenantId,
            connectionId,
            generationId,
            sitId,
            [
                CreateProfile(Guid.NewGuid(), "Pending profile", "PendingPropagation", ready: false),
                CreateProfile(Guid.NewGuid(), "Failed profile", "VerificationFailed", ready: false),
                CreateProfile(Guid.NewGuid(), "Ready profile", "Ready", ready: true)
            ]);
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());

        var cut = Render<Settings>();

        cut.WaitForElement("#purview-sensitive-information-type");
        cut.Find("#purview-sensitive-information-type").GetAttribute("value").Should().BeEmpty();
        cut.Find("#purview-sensitive-information-type").TextContent.Should()
            .Contain("EU Passport Number")
            .And.NotContain(sitId.ToString("D"));
        cut.Markup.Should().Contain("fixed tenant-wide Group");
        cut.Markup.Should().Contain("Individual scope");
        cut.Markup.Should().Contain("Pending propagation");
        cut.Markup.Should().Contain("Failed");
        cut.Markup.Should().Contain("Ready");
        cut.Markup.Should().NotContain("provider-policy-id");
        cut.Find("#purview-sensitive-information-type")
            .GetAttribute("aria-describedby").Should().NotBeNullOrWhiteSpace();
    }

    [Fact]
    public async Task TenantConnection_RequiresReviewThenConfirmationAndShowsSafeTimeline()
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var operationId = Guid.NewGuid();
        var inventoryGenerationId = Guid.NewGuid();
        var administratorId =
            Guid.Parse("02ed1e89-4ad1-4073-8e90-4aa865784896");
        var launch = CreateCompanionLaunch(
            operationId,
            tenantId,
            administratorId,
            inventoryGenerationId);
        const string rowVersion = "*";
        var reviewTicket = CreateReviewTicket(
            tenantId,
            "ConnectPurviewTenant",
            "PurviewTenantConnection",
            tenantId.ToString("D"),
            rowVersion);
        var confirmationTicket = CreateConfirmationTicket(
            reviewTicket.ReviewTokenId,
            tenantId,
            "ConnectPurviewTenant",
            "PurviewTenantConnection",
            tenantId.ToString("D"),
            rowVersion);
        _api.ReviewPurviewTenantConnectionAsync(
                Arg.Any<ReviewPurviewTenantConnectionRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationReviewTicket>(
                reviewTicket,
                "\"review\"",
                "review-correlation"));
        _api.ConfirmProtectionOperationReviewAsync(
                Arg.Any<ProtectionOperationReviewTicket>(),
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationConfirmationTicket>(
                confirmationTicket,
                "\"confirmation\"",
                "confirmation-correlation"));
        _api.StartPurviewTenantConnectionOperationAsync(
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Any<Guid>(),
                rowVersion,
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationAcceptedResponse>(
                new ProtectionOperationAcceptedResponse(
                    operationId,
                    "AwaitingAdministrator",
                    Guid.NewGuid(),
                    launch),
                "\"operation\"",
                "accepted-correlation"));
        _api.GetProtectionAdminOperationAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionAdminOperationResponse>(
                new ProtectionAdminOperationResponse(CreateOperation(operationId)),
                "\"operation\"",
                "operation-correlation"));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        var cut = Render<Settings>();
        var reviewButton = cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains("Review tenant connection"));

        await reviewButton.ClickAsync(new MouseEventArgs());

        cut.Find("[role='alertdialog']").TextContent.Should()
            .Contain("connect the Microsoft Purview tenant")
            .And.Contain("Gateway-reviewed")
            .And.Contain(tenantId.ToString("D"))
            .And.Contain("PurviewTenantConnection")
            .And.NotContain("synthetic-review-token");

        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            cut.Find("#protection-operation-heading").Should().NotBeNull();
            cut.Find(".operation-panel").GetAttribute("aria-live").Should().Be("polite");
            cut.Markup.Should().Contain("Finish on Windows");
            cut.Markup.Should().Contain("Correlation ID");
            cut.Markup.Should().NotContain("synthetic-confirmation-token");
        });
        var localArguments = launch.Arguments.ToArray();
        var fileIndex = Array.IndexOf(localArguments, "-File");
        localArguments[fileIndex + 1] = @".\Connect-PurviewTenant.ps1";
        var expectedCommand = "pwsh " +
            string.Join(" ", localArguments.Select(argument =>
                $"'{argument.Replace("'", "''", StringComparison.Ordinal)}'"));
        cut.Find(".command-text").TextContent.Should().Be(expectedCommand);
        expectedCommand.ToLowerInvariant().Should()
            .NotContain("token")
            .And.NotContain("secret");
        cut.Markup.Should()
            .Contain("Open PowerShell 7")
            .And.Contain("immutable deployed Admin UI image")
            .And.Contain("never runs it")
            .And.Contain("A365GW_CONNECTION_RESULT:");
        var download = cut.Find("a[download='Connect-PurviewTenant.ps1']");
        download.GetAttribute("href").Should().Be(
            "/downloads/Connect-PurviewTenant.ps1");
        cut.Find(".command-text").TextContent.Should()
            .Contain(@".\Connect-PurviewTenant.ps1")
            .And.NotContain(launch.ScriptRelativePath);
        cut.FindAll("fluent-button").Should().Contain(button =>
            button.TextContent.Contains("Copy command"));
        _ = _api.Received(1).StartPurviewTenantConnectionOperationAsync(
            Arg.Any<ProtectionOperationConfirmationTicket>(),
            Arg.Is<Guid>(value => value != Guid.Empty),
            rowVersion,
            Arg.Any<CancellationToken>());
        _ = _api.Received(1).ReviewPurviewTenantConnectionAsync(
            Arg.Is<ReviewPurviewTenantConnectionRequest>(request =>
                request.TenantId == tenantId &&
                request.ExpectedRowVersion == "*"),
            Arg.Any<CancellationToken>());
        Services.GetRequiredService<NavigationManager>().Uri.Should()
            .Contain($"operation={operationId:D}");
    }

    [Fact]
    public async Task KnowYourDataReview_UsesExplicitCurrentInventorySelection()
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var connectionId = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var sitId = Guid.NewGuid();
        ArrangeConnectedJourney(
            tenantId,
            connectionId,
            generationId,
            sitId,
            []);
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        _api.ReviewPurviewKnowYourDataOperationAsync(
                Arg.Any<ReviewPurviewKnowYourDataOperationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationReviewTicket>(
                CreateReviewTicket(
                    tenantId,
                    "CreateOrUpdateKnowYourData",
                    "KnowYourDataConfiguration",
                    Guid.NewGuid().ToString("D"),
                    "*",
                    sitId,
                    "EU Passport Number"),
                "\"review\"",
                "review-correlation"));
        var cut = Render<Settings>();
        cut.WaitForElement("#purview-sensitive-information-type");

        cut.Find("#purview-sensitive-information-type").Change("0");
        await cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains("Review fixed Know Your Data"))
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).ReviewPurviewKnowYourDataOperationAsync(
            Arg.Is<ReviewPurviewKnowYourDataOperationRequest>(request =>
                request.TenantConnectionId == connectionId &&
                request.SensitiveInformationType.InventoryGenerationId == generationId &&
                request.SensitiveInformationType.SensitiveInformationTypeId == sitId &&
                request.SensitiveInformationType.ExactName == "EU Passport Number" &&
                request.ExpectedRowVersion == "*"),
            Arg.Any<CancellationToken>());
        cut.Find("[role='alertdialog']").TextContent.Should()
            .Contain("Fixed tenant-wide Group")
            .And.Contain("EU Passport Number")
            .And.Contain(sitId.ToString("D"));
    }

    [Theory]
    [InlineData("AuditOnly")]
    [InlineData("Enforce")]
    public async Task NewDlpProfile_UsesWildcardAndConfirmsEveryExactBinding(string mode)
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var connectionId = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var sitId = Guid.NewGuid();
        var blueprintId = Guid.NewGuid();
        var targetId = Guid.NewGuid();
        ArrangeConnectedJourney(
            tenantId,
            connectionId,
            generationId,
            sitId,
            []);
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(new AgentIdentityBlueprintListResponse(
            [
                new AgentIdentityBlueprintSummaryDto(
                    Guid.NewGuid(),
                    blueprintId,
                    "Research blueprint",
                    true,
                    null)
            ]));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        _api.ReviewPurviewDlpProfileOperationAsync(
                Arg.Any<ReviewPurviewDlpProfileOperationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationReviewTicket>(
                CreateReviewTicket(
                    tenantId,
                    "CreateOrUpdateDlpProfile",
                    "DlpProfile",
                    targetId.ToString("D"),
                    "*",
                    sitId,
                    "EU Passport Number",
                    blueprintId),
                "\"review\"",
                "review-correlation"));
        var cut = Render<Settings>();
        cut.WaitForElement("#purview-sensitive-information-type");

        cut.Find("#purview-sensitive-information-type").Change("0");
        cut.Find("#dlp-blueprint").Change("0");
        cut.Find("#dlp-display-name").Change("Research protection");
        cut.Find("#dlp-mode").Change(mode);
        await cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains("Review new profile"))
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).ReviewPurviewDlpProfileOperationAsync(
            Arg.Is<ReviewPurviewDlpProfileOperationRequest>(request =>
                request.ProfileId == null &&
                request.BlueprintApplicationId == blueprintId &&
                request.SensitiveInformationType.SensitiveInformationTypeId == sitId &&
                request.ExpectedRowVersion == "*" &&
                request.Mode == mode &&
                request.Activities.SequenceEqual(new[] { "UploadText", "DownloadText" }) &&
                request.Actions.Count == 1 &&
                request.Actions[0] == new PurviewDlpRuleActionDto("UploadText", "Block")),
            Arg.Any<CancellationToken>());
        var dialog = cut.Find("[role='alertdialog']").TextContent;
        dialog.Should()
            .Contain(tenantId.ToString("D"))
            .And.Contain(targetId.ToString("D"))
            .And.Contain(blueprintId.ToString("D"))
            .And.Contain(sitId.ToString("D"))
            .And.Contain("Individual");
    }

    [Fact]
    public void OperationQuery_ReloadsDurableProgressWithoutGovernanceAccess()
    {
        _authorization.SetRoles(GatewayRoles.SupportReader);
        var operationId = Guid.NewGuid();
        Services.GetRequiredService<NavigationManager>()
            .NavigateTo($"/settings?operation={operationId:D}");
        _api.GetProtectionAdminOperationAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionAdminOperationResponse>(
                new ProtectionAdminOperationResponse(CreateOperation(operationId)),
                "\"operation\"",
                "operation-correlation"));

        var cut = Render<Settings>();

        cut.WaitForAssertion(() =>
        {
            cut.Find("#protection-operation-heading").Should().NotBeNull();
            cut.Markup.Should().Contain("The operation is waiting");
        });
        _api.Received(1).GetProtectionAdminOperationAsync(
            operationId,
            Arg.Any<CancellationToken>());
        _api.DidNotReceive()
            .GetPurviewTenantConnectionAsync(Arg.Any<CancellationToken>());
        _api.DidNotReceive()
            .GetPurviewSensitiveInformationTypesAsync(Arg.Any<CancellationToken>());
        _api.DidNotReceive()
            .GetPurviewKnowYourDataAsync(Arg.Any<CancellationToken>());
        _api.DidNotReceive()
            .GetPurviewDlpProfilesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task WindowsCompanionEvidence_IsValidatedReviewedAndCompleted()
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var administratorId = Guid.Parse("02ed1e89-4ad1-4073-8e90-4aa865784896");
        var operationId = Guid.NewGuid();
        var connectionId = Guid.NewGuid();
        var sitId = Guid.NewGuid();
        var rowVersion = Convert.ToBase64String([1, 2, 3, 4, 5, 6, 7, 8]);
        Services.GetRequiredService<NavigationManager>()
            .NavigateTo($"/settings?operation={operationId:D}");
        _api.GetPurviewTenantConnectionAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewTenantConnectionResponse>(
                new PurviewTenantConnectionResponse(
                    new PurviewTenantConnectionDto(
                        connectionId,
                        tenantId,
                        "AwaitingAdministrator",
                        "InteractiveDelegatedAdministrator",
                        null,
                        null,
                        null,
                        null,
                        DateTime.UtcNow.AddMinutes(15),
                        null,
                        null,
                        rowVersion)),
                rowVersion,
                "connection-correlation"));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        _api.GetProtectionAdminOperationAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionAdminOperationResponse>(
                new ProtectionAdminOperationResponse(CreateOperation(operationId)),
                "\"operation\"",
                "operation-correlation"));
        var observedAtUtc = DateTimeOffset.UtcNow.AddSeconds(-10);
        var inventoryGenerationId = Guid.NewGuid();
        var evidence = new PurviewTenantConnectionEvidenceDto(
            tenantId,
            administratorId,
            [
                "DlpPolicy.ReadWrite",
                "DlpRule.ReadWrite",
                "KnowYourData.ReadWrite",
                "SensitiveInformationTypes.Read"
            ],
            observedAtUtc,
            observedAtUtc.AddMinutes(10),
            [
                new PurviewSensitiveInformationTypeDto(
                    sitId,
                    "EU Passport Number",
                    "Microsoft")
            ]);
        var evidenceDigest = PurviewTenantConnectionEvidenceDigest.Compute(
            operationId,
            inventoryGenerationId,
            evidence);
        var review = CreateReviewTicket(
            tenantId,
            "CompletePurviewTenantConnection",
            "PurviewTenantConnection",
            tenantId.ToString("D"),
            rowVersion,
            sourceOperationId: operationId,
            inventoryGenerationId: inventoryGenerationId,
            evidenceDigest: evidenceDigest);
        _api.ReviewPurviewTenantConnectionCompletionAsync(
                operationId,
                inventoryGenerationId,
                Arg.Any<PurviewTenantConnectionEvidenceDto>(),
                rowVersion,
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationReviewTicket>(
                review,
                "\"review\"",
                "review-correlation"));
        _api.ConfirmProtectionOperationReviewAsync(
                Arg.Any<ProtectionOperationReviewTicket>(),
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationConfirmationTicket>(
                CreateConfirmationTicket(
                    review.ReviewTokenId,
                    tenantId,
                    "CompletePurviewTenantConnection",
                    "PurviewTenantConnection",
                    tenantId.ToString("D"),
                    rowVersion,
                    operationId,
                    inventoryGenerationId,
                    evidenceDigest),
                "\"confirmation\"",
                "confirmation-correlation"));
        _api.CompletePurviewTenantConnectionOperationAsync(
                operationId,
                Arg.Any<PurviewTenantConnectionEvidenceDto>(),
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Any<Guid>(),
                rowVersion,
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationAcceptedResponse>(
                new ProtectionOperationAcceptedResponse(
                    operationId,
                    "Completed",
                    Guid.NewGuid()),
                "\"operation\"",
                "accepted-correlation"));
        var cut = Render<Settings>();
        cut.WaitForElement("#purview-companion-evidence");

        var companionOutput = CreateLegitimateCompanionOutput(
            operationId,
            inventoryGenerationId,
            evidence,
            terminalLineEnding: "\r\n");
        DecodeCompanionJson(companionOutput).Should().Contain("+00:00");
        var file = InputFileContent.CreateFromText(
            companionOutput,
            "purview-companion-output.txt",
            DateTimeOffset.UtcNow,
            "text/plain");
        cut.FindComponent<InputFile>().UploadFiles(file);
        cut.WaitForAssertion(() =>
            cut.Markup.Should().Contain("Evidence checked for this tenant"));
        await cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains("Review companion completion"))
            .ClickAsync(new MouseEventArgs());
        var bindingDialog = cut.Find("[role='alertdialog']").TextContent;
        bindingDialog.Should()
            .Contain(operationId.ToString("D"))
            .And.Contain(inventoryGenerationId.ToString("D"))
            .And.Contain(evidenceDigest)
            .And.Contain("Submit companion evidence for verification");
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).ReviewPurviewTenantConnectionCompletionAsync(
            operationId,
            inventoryGenerationId,
            Arg.Is<PurviewTenantConnectionEvidenceDto>(value =>
                value.TenantId == tenantId &&
                value.ObservedAtUtc.Offset == TimeSpan.Zero &&
                value.InventoryExpiresAtUtc.Offset == TimeSpan.Zero),
            rowVersion,
            Arg.Any<CancellationToken>());
        _ = _api.DidNotReceive().ReviewPurviewTenantConnectionAsync(
            Arg.Any<ReviewPurviewTenantConnectionRequest>(),
            Arg.Any<CancellationToken>());
        _ = _api.Received(1).CompletePurviewTenantConnectionOperationAsync(
            operationId,
            Arg.Is<PurviewTenantConnectionEvidenceDto>(value =>
                value.TenantId == tenantId &&
                value.AdministratorObjectId == administratorId &&
                value.SensitiveInformationTypes.Single().Id == sitId),
            Arg.Any<ProtectionOperationConfirmationTicket>(),
            Arg.Is<Guid>(value => value != Guid.Empty),
            rowVersion,
            Arg.Any<CancellationToken>());
        cut.Markup.Should().NotContain("synthetic-confirmation-token");
    }

    [Fact]
    public void CompanionUpload_RejectsRawJsonMalformedDuplicateAndExtraOutput()
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var administratorId = Guid.Parse("02ed1e89-4ad1-4073-8e90-4aa865784896");
        var operationId = Guid.NewGuid();
        var connectionId = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var rowVersion = Convert.ToBase64String([1, 2, 3, 4, 5, 6, 7, 8]);
        Services.GetRequiredService<NavigationManager>()
            .NavigateTo($"/settings?operation={operationId:D}");
        _api.GetPurviewTenantConnectionAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewTenantConnectionResponse>(
                new PurviewTenantConnectionResponse(
                    new PurviewTenantConnectionDto(
                        connectionId,
                        tenantId,
                        "AwaitingAdministrator",
                        "InteractiveDelegatedAdministrator",
                        null,
                        null,
                        null,
                        null,
                        DateTime.UtcNow.AddMinutes(15),
                        null,
                        null,
                        rowVersion)),
                rowVersion,
                "connection-correlation"));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        _api.GetProtectionAdminOperationAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionAdminOperationResponse>(
                new ProtectionAdminOperationResponse(CreateOperation(operationId)),
                "\"operation\"",
                "operation-correlation"));
        var observedAtUtc = DateTimeOffset.UtcNow.AddSeconds(-10);
        var evidence = new PurviewTenantConnectionEvidenceDto(
            tenantId,
            administratorId,
            [
                "DlpPolicy.ReadWrite",
                "DlpRule.ReadWrite",
                "KnowYourData.ReadWrite",
                "SensitiveInformationTypes.Read"
            ],
            observedAtUtc,
            observedAtUtc.AddMinutes(10),
            [
                new PurviewSensitiveInformationTypeDto(
                    Guid.NewGuid(),
                    "EU Passport Number",
                    "Microsoft")
            ]);
        var valid = CreateLegitimateCompanionOutput(
            operationId,
            generationId,
            evidence);
        var encodedPayload = valid["A365GW_CONNECTION_RESULT:".Length..];
        var rawJson = System.Text.Encoding.UTF8.GetString(
            Convert.FromBase64String(encodedPayload));
        var jsonWithUnknownMember = rawJson[..^1] + ",\"providerBody\":\"not-allowed\"}";
        string[] invalidOutputs =
        [
            System.Text.Json.JsonSerializer.Serialize(evidence),
            "A365GW_CONNECTION_RESULT:" +
                Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(
                    System.Text.Json.JsonSerializer.Serialize(evidence))),
            rawJson,
            encodedPayload,
            "A365GW_CONNECTION_RESULT:",
            "A365GW_CONNECTION_RESULT:%%%",
            $"{valid}{valid}",
            $"{valid}\n{valid}",
            $"Companion completed\n{valid}",
            $"{valid}\nAdditional output",
            $"{valid}\n\n",
            "A365GW_CONNECTION_RESULT:" +
                Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(
                    jsonWithUnknownMember))
        ];
        var cut = Render<Settings>();
        cut.WaitForElement("#purview-companion-evidence");

        foreach (var invalid in invalidOutputs)
        {
            cut.FindComponent<InputFile>().UploadFiles(
                InputFileContent.CreateFromText(
                    invalid,
                    "purview-companion-output.txt",
                    DateTimeOffset.UtcNow,
                    "text/plain"));
            cut.WaitForAssertion(() =>
            {
                cut.Find("[role='alert']").TextContent.Should()
                    .Contain("not the single fresh result");
                cut.FindAll("fluent-button").Single(button =>
                    button.TextContent.Contains("Review companion completion"))
                    .HasAttribute("disabled").Should().BeTrue();
            });
        }

        cut.FindComponent<InputFile>().UploadFiles(
            InputFileContent.CreateFromText(
                new string('A', (512 * 1024) + 1),
                "oversized-companion-output.txt",
                DateTimeOffset.UtcNow,
                "text/plain"));
        cut.Find("[role='alert']").TextContent.Should()
            .Contain("larger than the supported 512 KB limit");

        _ = _api.DidNotReceive().ReviewPurviewTenantConnectionAsync(
            Arg.Any<ReviewPurviewTenantConnectionRequest>(),
            Arg.Any<CancellationToken>());
        _ = _api.DidNotReceive().ReviewPurviewTenantConnectionCompletionAsync(
            Arg.Any<Guid>(),
            Arg.Any<Guid>(),
            Arg.Any<PurviewTenantConnectionEvidenceDto>(),
            Arg.Any<string>(),
            Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData("Review reconcile", false)]
    [InlineData("Review runtime check", true)]
    public async Task ProfileRecoveryActions_UseReviewedConfirmation(
        string buttonLabel,
        bool runtimeValidation)
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var connectionId = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var sitId = Guid.NewGuid();
        var profile = CreateRuntimeCandidateProfile(Guid.NewGuid(), sitId);
        var operationId = Guid.NewGuid();
        ArrangeConnectedJourney(
            tenantId,
            connectionId,
            generationId,
            sitId,
            [profile]);
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        var operationType = runtimeValidation
            ? "ValidateDlpRuntime"
            : "ReconcileDlpProfile";
        var review = CreateReviewTicket(
            tenantId,
            operationType,
            "DlpProfile",
            profile.Id.ToString("D"),
            profile.RowVersion,
            sitId,
            "EU Passport Number");
        var reviewResource =
            new GatewayApiResource<ProtectionOperationReviewTicket>(
                review,
                "\"review\"",
                "review-correlation");
        _api.ReviewReconcilePurviewDlpProfileAsync(
                profile.Id,
                profile.RowVersion,
                Arg.Any<CancellationToken>())
            .Returns(reviewResource);
        _api.ReviewValidatePurviewDlpRuntimeAsync(
                profile.Id,
                profile.RowVersion,
                Arg.Any<CancellationToken>())
            .Returns(reviewResource);
        _api.ConfirmProtectionOperationReviewAsync(
                Arg.Any<ProtectionOperationReviewTicket>(),
                Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionOperationConfirmationTicket>(
                CreateConfirmationTicket(
                    review.ReviewTokenId,
                    tenantId,
                    operationType,
                    "DlpProfile",
                    profile.Id.ToString("D"),
                    profile.RowVersion),
                "\"confirmation\"",
                "confirmation-correlation"));
        var accepted = new GatewayApiResource<ProtectionOperationAcceptedResponse>(
            new ProtectionOperationAcceptedResponse(operationId, "Pending", Guid.NewGuid()),
            "\"operation\"",
            "accepted-correlation");
        _api.ReconcilePurviewDlpProfileAsync(
                profile.Id,
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Any<Guid>(),
                profile.RowVersion,
                Arg.Any<CancellationToken>())
            .Returns(accepted);
        _api.ValidatePurviewDlpProfileRuntimeAsync(
                profile.Id,
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Any<Guid>(),
                profile.RowVersion,
                Arg.Any<CancellationToken>())
            .Returns(accepted);
        _api.GetProtectionAdminOperationAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<ProtectionAdminOperationResponse>(
                new ProtectionAdminOperationResponse(CreateOperation(operationId)),
                "\"operation\"",
                "operation-correlation"));
        var cut = Render<Settings>();
        cut.WaitForElement(".profile-card");

        await cut.FindAll("fluent-button").Single(button =>
            button.TextContent.Contains(buttonLabel)).ClickAsync(new MouseEventArgs());
        var dialog = cut.Find("[role='alertdialog']").TextContent;
        if (runtimeValidation)
        {
            dialog.Should()
                .Contain("Run the runtime readiness check")
                .And.Contain("bounded synthetic allow and block check")
                .And.Contain("Start runtime check");
        }
        else
        {
            dialog.Should()
                .Contain("Reconcile this DLP profile")
                .And.Contain("does not silently rewrite policy")
                .And.Contain("Start reconciliation");
        }

        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        if (runtimeValidation)
        {
            _ = _api.Received(1).ReviewValidatePurviewDlpRuntimeAsync(
                profile.Id,
                profile.RowVersion,
                Arg.Any<CancellationToken>());
            _ = _api.DidNotReceive().ReviewReconcilePurviewDlpProfileAsync(
                profile.Id,
                profile.RowVersion,
                Arg.Any<CancellationToken>());
            _ = _api.Received(1).ValidatePurviewDlpProfileRuntimeAsync(
                profile.Id,
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Is<Guid>(value => value != Guid.Empty),
                profile.RowVersion,
                Arg.Any<CancellationToken>());
            _ = _api.DidNotReceive().ReconcilePurviewDlpProfileAsync(
                profile.Id,
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Any<Guid>(),
                profile.RowVersion,
                Arg.Any<CancellationToken>());
        }
        else
        {
            _ = _api.Received(1).ReviewReconcilePurviewDlpProfileAsync(
                profile.Id,
                profile.RowVersion,
                Arg.Any<CancellationToken>());
            _ = _api.DidNotReceive().ReviewValidatePurviewDlpRuntimeAsync(
                profile.Id,
                profile.RowVersion,
                Arg.Any<CancellationToken>());
            _ = _api.Received(1).ReconcilePurviewDlpProfileAsync(
                profile.Id,
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Is<Guid>(value => value != Guid.Empty),
                profile.RowVersion,
                Arg.Any<CancellationToken>());
            _ = _api.DidNotReceive().ValidatePurviewDlpProfileRuntimeAsync(
                profile.Id,
                Arg.Any<ProtectionOperationConfirmationTicket>(),
                Arg.Any<Guid>(),
                profile.RowVersion,
                Arg.Any<CancellationToken>());
        }
        _ = _api.DidNotReceive().ReviewPurviewDlpProfileOperationAsync(
            Arg.Any<ReviewPurviewDlpProfileOperationRequest>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void AuditOnlyProfile_CannotOfferAllowBlockRuntimeValidation()
    {
        var tenantId = Guid.Parse("7b57f2b7-5ec8-49fb-a1c2-5d68f2b2f747");
        var sitId = Guid.NewGuid();
        var profile = CreateRuntimeCandidateProfile(Guid.NewGuid(), sitId) with { Mode = "AuditOnly" };
        ArrangeConnectedJourney(tenantId, Guid.NewGuid(), Guid.NewGuid(), sitId, [profile]);
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());
        var cut = Render<Settings>();
        cut.WaitForElement(".profile-card");

        cut.FindAll("fluent-button").Single(button => button.TextContent.Contains("Review runtime check"))
            .HasAttribute("disabled").Should().BeTrue();
        cut.Markup.Should().Contain("Audit-only profiles cannot complete the allow and block runtime check.");
    }

    [Fact]
    public void ProtectionDefaults_CannotBeTurnedOnUntilServerReadinessIsReady()
    {
        _api.GetProtectionCapabilitiesAsync(Arg.Any<CancellationToken>())
            .Returns(Capabilities(
                ("Agent365RegistrationBeta", "Installed"),
                ("PromptShields", "PendingPropagation"),
                ("Purview", "Installed")));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig() with { PromptShieldAvailable = true });

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#default-prompt-shield-enabled").HasAttribute("disabled").Should().BeTrue();
        cut.Find("#default-purview-enabled").HasAttribute("disabled").Should().BeTrue();
        cut.Markup.Should().Contain("Unavailable for a new default");
    }

    private static SystemConfigDto CreateConfig(
        string legacyMode = "Agent365",
        bool? agent365Enabled = true,
        bool? azureMonitorEnabled = false) => new(
        ProvisioningMode: "Automatic",
        DefaultObservabilityMode: legacyMode,
        DefaultPurviewEnabled: false,
        DefaultPurviewMode: "AuditOnly",
        RetentionDaysActivityReceipts: 30,
        RetentionDaysAuditEvents: 90,
        RetentionDaysIdempotencyRecords: 7,
        RetentionDaysOutboxMessages: 14,
        RateLimitPerClient: 100,
        RateLimitPerAgent: 200,
        RateLimitGlobal: 1_000,
        ReconciliationEnabled: true,
        ReconciliationIntervalHours: 24,
        StuckTransitionTimeoutDays: 7,
        UseGraphAgentRegistration: false,
        UseCliProvisioningFallback: true,
        DefaultAgent365ObservabilityEnabled: agent365Enabled,
        DefaultAzureMonitorExportEnabled: azureMonitorEnabled);

    private void ArrangeConnectedJourney(
        Guid tenantId,
        Guid connectionId,
        Guid generationId,
        Guid sitId,
        IReadOnlyList<PurviewDlpProfileDto> profiles)
    {
        var connectionRowVersion =
            Convert.ToBase64String([1, 2, 3, 4, 5, 6, 7, 8]);
        _api.GetPurviewTenantConnectionAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewTenantConnectionResponse>(
                new PurviewTenantConnectionResponse(
                    new PurviewTenantConnectionDto(
                        connectionId,
                        tenantId,
                        "Connected",
                        "Application",
                        null,
                        null,
                        generationId,
                        DateTime.UtcNow.AddMinutes(-5),
                        DateTime.UtcNow.AddMinutes(30),
                        DateTime.UtcNow.AddMinutes(-2),
                        null,
                        connectionRowVersion)),
                connectionRowVersion,
                "connection-correlation"));
        _api.GetPurviewSensitiveInformationTypesAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewSensitiveInformationTypeListResponse>(
                new PurviewSensitiveInformationTypeListResponse(
                    generationId,
                    tenantId,
                    DateTime.UtcNow.AddMinutes(-2),
                    DateTime.UtcNow.AddMinutes(30),
                    false,
                    [new PurviewSensitiveInformationTypeDto(
                        sitId,
                        "EU Passport Number",
                        "Microsoft")]),
                "\"inventory\"",
                "inventory-correlation"));
        _api.GetPurviewKnowYourDataAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewKnowYourDataResponse>(
                new PurviewKnowYourDataResponse(null),
                null,
                "kyd-correlation"));
        _api.GetPurviewDlpProfilesAsync(Arg.Any<CancellationToken>())
            .Returns(new GatewayApiResource<PurviewDlpProfileListResponse>(
                new PurviewDlpProfileListResponse(profiles),
                null,
                "profiles-correlation"));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(new AgentIdentityBlueprintListResponse(
                profiles.Select(profile => new AgentIdentityBlueprintSummaryDto(
                    Guid.NewGuid(),
                    profile.BlueprintApplicationId,
                    $"{profile.DisplayName} blueprint",
                    true,
                    null)).ToArray()));
    }

    private static GatewayApiResource<ProtectionCapabilitiesResponse> Capabilities(
        params (string Name, string Status)[] items) => new(
        new ProtectionCapabilitiesResponse(
            items.Select(item => new ProtectionCapabilityDto(
                Guid.NewGuid(),
                item.Name,
                item.Status,
                new ProtectionCapabilityResourceIdentifiersDto(
                    null,
                    "provider-resource-id",
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null),
                DateTime.UtcNow,
                null,
                "capability-row")).ToArray()),
        "\"capabilities\"",
        "capability-correlation");

    private static string CreateLegitimateCompanionOutput(
        Guid operationId,
        Guid inventoryGenerationId,
        PurviewTenantConnectionEvidenceDto evidence,
        string terminalLineEnding = "")
    {
        var payload = new
        {
            operationId,
            tenantId = evidence.TenantId,
            administratorObjectId = evidence.AdministratorObjectId,
            inventoryGenerationId,
            observedAtUtc = evidence.ObservedAtUtc,
            inventoryExpiresAtUtc = evidence.InventoryExpiresAtUtc,
            authorizedCapabilities = evidence.AuthorizedCapabilities,
            sensitiveInformationTypes = evidence.SensitiveInformationTypes
        };
        var json = System.Text.Json.JsonSerializer.Serialize(
            payload,
            new System.Text.Json.JsonSerializerOptions
            {
                PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase
            });
        var encoded = Convert.ToBase64String(
            System.Text.Encoding.UTF8.GetBytes(json));
        return $"A365GW_CONNECTION_RESULT:{encoded}{terminalLineEnding}";
    }

    private static PurviewCompanionLaunchDto CreateCompanionLaunch(
        Guid operationId,
        Guid tenantId,
        Guid administratorId,
        Guid inventoryGenerationId)
    {
        const string scriptPath = "Automation/Connect-PurviewTenant.ps1";
        var expiresAtUtc = DateTimeOffset.UtcNow.AddMinutes(10);
        return new PurviewCompanionLaunchDto(
            operationId,
            inventoryGenerationId,
            expiresAtUtc,
            scriptPath,
            [
                "-NoLogo",
                "-NoProfile",
                "-File",
                scriptPath,
                "-OperationId",
                operationId.ToString("D"),
                "-TenantId",
                tenantId.ToString("D"),
                "-AdministratorObjectId",
                administratorId.ToString("D"),
                "-InventoryGenerationId",
                inventoryGenerationId.ToString("D"),
                "-ExpiresAtUtc",
                expiresAtUtc.ToString("O")
            ]);
    }

    private static string DecodeCompanionJson(string output)
    {
        var line = output.TrimEnd('\r', '\n');
        var encoded = line["A365GW_CONNECTION_RESULT:".Length..];
        return System.Text.Encoding.UTF8.GetString(
            Convert.FromBase64String(encoded));
    }

    private static PurviewDlpProfileDto CreateProfile(
        Guid blueprintId,
        string name,
        string status,
        bool ready) => new(
        Guid.NewGuid(),
        blueprintId,
        name,
        Guid.NewGuid(),
        "EU Passport Number",
        "AuditOnly",
        ["UploadText", "DownloadText"],
        [new PurviewDlpRuleActionDto("UploadText", "Block")],
        status,
        new ProtectionReadinessDto(
            "Installed",
            ready ? "Ready" : status == "VerificationFailed" ? "Failed" : "Ready",
            ready ? "Ready" : status == "PendingPropagation" ? "Pending" : "Failed",
            ready ? "Ready" : "NotChecked",
            ready ? "Ready" : "NotChecked",
            ready,
            ready ? [] : status == "PendingPropagation"
                ? ["PropagationPending"]
                : ["PolicyReadbackMismatch"],
            DateTime.UtcNow),
        "provider-policy-id",
        "provider-rule-id",
        DateTime.UtcNow,
        Convert.ToBase64String([2, 3, 4, 5, 6, 7, 8, 9]));

    private static PurviewDlpProfileDto CreateRuntimeCandidateProfile(
        Guid blueprintId,
        Guid sitId) => new(
        Guid.NewGuid(),
        blueprintId,
        "Runtime candidate",
        sitId,
        "EU Passport Number",
        "Enforce",
        ["UploadText", "DownloadText"],
        [new PurviewDlpRuleActionDto("UploadText", "Block")],
        "Pending",
        new ProtectionReadinessDto(
            "Installed",
            "Ready",
            "Ready",
            "Ready",
            "NotChecked",
            false,
            ["RuntimeValidationRequired"],
            DateTime.UtcNow),
        null,
        null,
        DateTime.UtcNow,
        Convert.ToBase64String([3, 4, 5, 6, 7, 8, 9, 10]));

    private static ProtectionOperationReviewTicket CreateReviewTicket(
        Guid tenantId,
        string operationType,
        string targetType,
        string targetIdentifier,
        string rowVersion,
        Guid? sensitiveInformationTypeId = null,
        string? sensitiveInformationTypeName = null,
        Guid? blueprintApplicationId = null,
        Guid? sourceOperationId = null,
        Guid? inventoryGenerationId = null,
        string? evidenceDigest = null) =>
        new(
            new ProtectionOperationReviewResponse(
                Guid.NewGuid(),
                "synthetic-review-token",
                "synthetic-payload-hash",
                DateTime.UtcNow.AddMinutes(5),
                new ProtectionOperationReviewSummaryDto(
                    tenantId,
                    operationType,
                    targetType,
                    targetIdentifier,
                    blueprintApplicationId,
                    sensitiveInformationTypeId,
                    sensitiveInformationTypeName,
                    "AuditOnly",
                    ["UploadText", "DownloadText"],
                    [new PurviewDlpRuleActionDto("UploadText", "Block")],
                    targetType switch
                    {
                        "KnowYourDataConfiguration" => "Group",
                        "DlpProfile" => "Individual",
                        _ => "Tenant"
                    },
                    "Application",
                    "Readback does not prove propagation or a runtime verdict.",
                    sourceOperationId,
                    inventoryGenerationId,
                    evidenceDigest)),
            rowVersion);

    private static ProtectionOperationConfirmationTicket CreateConfirmationTicket(
        Guid reviewTokenId,
        Guid tenantId,
        string operationType,
        string targetType,
        string targetIdentifier,
        string rowVersion,
        Guid? sourceOperationId = null,
        Guid? inventoryGenerationId = null,
        string? evidenceDigest = null) =>
        new(
            new ProtectionOperationConfirmationResponse(
                reviewTokenId,
                Guid.NewGuid(),
                "synthetic-confirmation-token",
                DateTime.UtcNow.AddMinutes(5)),
            new ProtectionOperationReviewSummaryDto(
                tenantId,
                operationType,
                targetType,
                targetIdentifier,
                null,
                null,
                null,
                null,
                [],
                [],
                "Application",
                "Application",
                "Readback does not prove propagation or a runtime verdict.",
                sourceOperationId,
                inventoryGenerationId,
                evidenceDigest),
            rowVersion);

    private static ProtectionAdminOperationDto CreateOperation(Guid operationId) => new(
        operationId,
        1,
        "ConnectPurviewTenant",
        "AwaitingAdministrator",
        Guid.NewGuid(),
        "administrator",
        "PurviewTenantConnection",
        "tenant",
        "payload-hash",
        Guid.NewGuid(),
        "connection-row",
        "None",
        1,
        3,
        null,
        false,
        false,
        Guid.NewGuid(),
        null,
        null,
        "CompletePurviewTenantConnection",
        ["AwaitingAdministrator"],
        DateTime.UtcNow.AddMinutes(-1),
        DateTime.UtcNow.AddMinutes(-1),
        null,
        DateTime.UtcNow,
        [
            new ProtectionAdminOperationStepDto(
                Guid.NewGuid(),
                0,
                "ValidateReviewedIntent",
                "Completed",
                1,
                "None",
                null,
                false,
                false,
                null,
                null,
                DateTime.UtcNow.AddMinutes(-1),
                DateTime.UtcNow)
        ],
        "operation-row");
}
