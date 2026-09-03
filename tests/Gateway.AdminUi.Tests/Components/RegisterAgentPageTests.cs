using System.Security.Claims;
using Bunit;
using Bunit.TestDoubles;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
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

public sealed class RegisterAgentPageTests : BunitContext
{
    private static readonly Guid ExistingBlueprintObjectId =
        Guid.Parse("3acbfa00-3f19-4ea9-848a-d642b54a962c");
    private static readonly Guid ExistingBlueprintClientId =
        ExistingBlueprintObjectId;
    private static readonly Guid AnalyticsBlueprintObjectId =
        Guid.Parse("5d290fb2-0762-491f-8bdb-cfc925a5fa87");
    private static readonly Guid AnalyticsBlueprintClientId =
        Guid.Parse("1abf99d9-a08b-45cc-a3ec-2d2ee77df038");
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();
    private readonly BunitAuthorizationContext _authorization;

    public RegisterAgentPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;

        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig("Agent365", agent365Enabled: true, azureMonitorEnabled: false));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(CreateBlueprintInventory());
        _api.GetPurviewPolicyProfilesAsync(Arg.Any<CancellationToken>())
            .Returns(new PurviewPolicyProfileListResponse(
            [
                new PurviewPolicyProfileSummaryDto(
                    Guid.Parse("cfe7a481-8295-4f6a-a54b-434b1e9cb66c"),
                    "Enterprise AI protection",
                    "AllSensitiveInformation",
                    "AuditOnly",
                    "Ready",
                    2,
                    DateTime.UtcNow)
            ]));

        _authorization = AddAuthorization();
        _authorization.SetAuthorized("Admin user");
        _authorization.SetRoles(GatewayRoles.Administrator);
    }

    [Fact]
    public void BlueprintSelection_DefaultsToExistingTypedInventoryAndAcceptsEqualGraphIdentifiers()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));

        var cut = Render<RegisterAgent>();

        var select = cut.Find("#existing-blueprint");
        select.Should().NotBeNull();
        var options = select.QuerySelectorAll("option");
        options.Should().HaveCount(3);
        options[0].TextContent.Should().Be("Select an Agent 365-compatible blueprint");
        options[1].TextContent.Should().StartWith("Analytics blueprint");
        options[2].TextContent.Should().StartWith("Shared research blueprint");
        options.Should().Contain(option =>
            option.GetAttribute("value") == ExistingBlueprintObjectId.ToString("D") &&
            option.TextContent.Contains("Shared research blueprint") &&
            option.TextContent.Contains(ExistingBlueprintObjectId.ToString("D")));
        var analyticsOption = options.Single(option =>
            option.GetAttribute("value") == AnalyticsBlueprintObjectId.ToString("D"));
        analyticsOption.HasAttribute("disabled").Should().BeFalse();
        analyticsOption.TextContent.Should().Contain(AnalyticsBlueprintObjectId.ToString("D"));
        analyticsOption.TextContent.Should().NotContain(AnalyticsBlueprintClientId.ToString("D"));
        cut.FindAll("#new-blueprint-display-name").Should().BeEmpty();
        cut.FindAll("#existing-blueprint-object-id").Should().BeEmpty();
        cut.FindAll("#runtime-managed-identity-object-id").Should().BeEmpty();
        cut.Find("#existing-blueprint-help").TextContent.Should().Contain("may be the same GUID");
        cut.Markup.Should().Contain("Only typed Agent ID blueprints are listed");
    }

    [Fact]
    public void NewProtectedBlueprint_OffersExistingOrNewPurviewProfile()
    {
        _authorization.SetClaims(new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));
        var cut = Render<RegisterAgent>();

        cut.Find("#blueprint-mode").Change("CreateNew");
        cut.Find("#purview-enabled").Change(true);

        cut.Find("#purview-profile-mode").Should().NotBeNull();
        cut.Find("#purview-profile").TextContent.Should().Contain("Enterprise AI protection");
        cut.Find("#purview-profile").TextContent.Should().Contain("2 blueprints");

        cut.Find("#purview-profile-mode").Change("CreateNew");
        cut.Find("#new-purview-profile-name").Should().NotBeNull();
        cut.Markup.Should().Contain("preserves every existing DLP location");
    }

    [Fact]
    public async Task IncompatibleBlueprints_RemainVisibleButCannotBeSelectedOrSubmitted()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(new AgentIdentityBlueprintListResponse(
            [
                new AgentIdentityBlueprintSummaryDto(
                    ExistingBlueprintObjectId,
                    ExistingBlueprintClientId,
                    "Legacy blueprint",
                    IsAgent365Compatible: false,
                    Agent365CompatibilityIssue: "MissingRequiredManagerApplications")
            ]));

        var cut = Render<RegisterAgent>();

        var unavailableOption = cut.FindAll("#existing-blueprint option").Single(option =>
            option.GetAttribute("value") == ExistingBlueprintObjectId.ToString("D"));
        unavailableOption.HasAttribute("disabled").Should().BeTrue();
        unavailableOption.TextContent.Should().Contain("Unavailable for Agent 365");
        cut.Find("#blueprint-inventory-status").TextContent.Should().Contain(
            "not compatible with Agent 365");
        cut.Find("[role='alert']").TextContent.Should().Contain(
            "No existing blueprint is compatible with Agent 365");
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();

        cut.Find("#agent-name").Change("Research agent");
        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.DidNotReceive().RegisterAgentAsync(
            Arg.Any<RegisterAgentRequest>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void SmallBlueprintInventory_DoesNotOfferAFilter()
    {
        _authorization.SetClaims(new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));

        var cut = Render<RegisterAgent>();

        cut.FindAll("#blueprint-filter").Should().BeEmpty();
    }

    [Fact]
    public void LargeBlueprintInventory_ListsAvailableBlueprintsBeforeUnavailableOnes()
    {
        _authorization.SetClaims(new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(CreateLargeBlueprintInventory(compatible: 9, incompatible: 36));

        var cut = Render<RegisterAgent>();

        var groups = cut.FindAll("#existing-blueprint optgroup");
        groups.Should().HaveCount(2);
        groups[0].GetAttribute("label").Should().Contain("Available");
        groups[1].GetAttribute("label").Should().Contain("Unavailable");
        groups[0].QuerySelectorAll("option").Should().HaveCount(9);
        groups[1].QuerySelectorAll("option").Should().HaveCount(36);
        groups[0].QuerySelectorAll("option")
            .Should().OnlyContain(option => !option.HasAttribute("disabled"));
        groups[1].QuerySelectorAll("option")
            .Should().OnlyContain(option => option.HasAttribute("disabled"));
        cut.Find("#blueprint-filter").Should().NotBeNull();
    }

    [Fact]
    public void BlueprintFilter_NarrowsBothGroupsAndReportsTheMatchCount()
    {
        _authorization.SetClaims(new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(CreateLargeBlueprintInventory(compatible: 9, incompatible: 36));

        var cut = Render<RegisterAgent>();
        cut.Find("#blueprint-filter").Input("Available 03");

        var options = cut.FindAll("#existing-blueprint optgroup option");
        options.Should().HaveCount(1);
        options[0].TextContent.Should().Contain("Available blueprint 03");
        cut.Find("#blueprint-filter-status").TextContent.Should().Contain("1");
    }

    [Fact]
    public void BlueprintFilter_KeepsTheCurrentSelectionVisibleWhenItNoLongerMatches()
    {
        _authorization.SetClaims(new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(CreateLargeBlueprintInventory(compatible: 9, incompatible: 36));

        var cut = Render<RegisterAgent>();
        var selected = LargeInventoryObjectId(1).ToString("D");
        cut.Find("#existing-blueprint").Change(selected);
        cut.Find("#blueprint-filter").Input("Available 07");

        var options = cut.FindAll("#existing-blueprint optgroup option");
        options.Should().HaveCount(2);
        options.Should().Contain(option => option.GetAttribute("value") == selected);
    }

    [Fact]
    public void BlueprintFilter_ExplainsWhenNothingMatches()
    {
        _authorization.SetClaims(new Claim("oid", "02ed1e89-4ad1-4073-8e90-4aa865784896"));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(CreateLargeBlueprintInventory(compatible: 9, incompatible: 36));

        var cut = Render<RegisterAgent>();
        cut.Find("#blueprint-filter").Input("no-such-blueprint");

        cut.FindAll("#existing-blueprint optgroup option").Should().BeEmpty();
        cut.Find("#blueprint-filter-status").TextContent
            .Should().Contain("No blueprint matches");
    }

    [Fact]
    public async Task MissingBlueprintSelection_FailsValidationWithoutSubmitting()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        cut.Markup.Should().Contain("Select a reusable Agent ID blueprint");
        _ = _api.DidNotReceive().RegisterAgentAsync(
            Arg.Any<RegisterAgentRequest>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void BlueprintInventoryLoading_ShowsAccessibleStatusAndBlocksExistingSubmission()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var completion = new TaskCompletionSource<AgentIdentityBlueprintListResponse>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(completion.Task);

        var cut = Render<RegisterAgent>();

        var status = cut.Find("[role='status']");
        status.GetAttribute("aria-live").Should().Be("polite");
        status.TextContent.Should().Contain("Loading reusable blueprints");
        cut.FindAll("#existing-blueprint").Should().BeEmpty();
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();

        completion.SetResult(CreateBlueprintInventory());
        cut.WaitForAssertion(() => cut.Find("#existing-blueprint").Should().NotBeNull());
    }

    [Fact]
    public async Task BlueprintInventoryFailure_ShowsSafeCorrelationAndRetryWithoutClaimingEmpty()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var attempts = 0;
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(_ => ++attempts == 1
                ? Task.FromException<AgentIdentityBlueprintListResponse>(
                    new GatewayApiProtocolException(
                        "The blueprint inventory could not be verified.",
                        "blueprint-correlation"))
                : Task.FromResult(CreateBlueprintInventory()));

        var cut = Render<RegisterAgent>();

        var alert = cut.Find("[role='alert']");
        alert.TextContent.Should().Contain("Blueprint choices are unavailable");
        alert.TextContent.Should().Contain("blueprint-correlation");
        cut.Markup.Should().NotContain("No reusable blueprints found");
        cut.Markup.Should().Contain("no empty inventory is being claimed");
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();

        var retry = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Try again");
        await retry.ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() => cut.Find("#existing-blueprint").Should().NotBeNull());
        _ = _api.Received(2).GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task EmptyBlueprintInventory_OffersRefreshAndCreateNewWithoutSubmittingTheForm()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(new AgentIdentityBlueprintListResponse([]));

        var cut = Render<RegisterAgent>();

        cut.Markup.Should().Contain("No reusable blueprints found");
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();
        var createNew = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Create a reusable blueprint");

        await createNew.ClickAsync(new MouseEventArgs());

        cut.Find("#new-blueprint-display-name").Should().NotBeNull();
        cut.FindAll("#existing-blueprint").Should().BeEmpty();
        _ = _api.DidNotReceive().RegisterAgentAsync(
            Arg.Any<RegisterAgentRequest>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task RefreshBlueprints_ClearsASelectionThatIsNoLongerAvailable()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var attempts = 0;
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(_ => ++attempts == 1
                ? Task.FromResult(CreateBlueprintInventory())
                : Task.FromResult(new AgentIdentityBlueprintListResponse(
                [
                    new AgentIdentityBlueprintSummaryDto(
                        AnalyticsBlueprintObjectId,
                        AnalyticsBlueprintClientId,
                        "Analytics blueprint",
                        IsAgent365Compatible: true,
                        Agent365CompatibilityIssue: null)
                ])));
        var cut = Render<RegisterAgent>();
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));

        var refresh = cut.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Refresh blueprints");
        await refresh.ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
            cut.Find("#existing-blueprint").GetAttribute("value").Should().BeNullOrEmpty());
        cut.Find("#blueprint-inventory-status").TextContent.Should().Contain("1 reusable blueprint loaded");
    }

    [Fact]
    public async Task CreateNew_RemainsAvailableWhenBlueprintInventoryCannotBeLoaded()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        const string blueprintDisplayName = "New gateway blueprint";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetAgentIdentityBlueprintsAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromException<AgentIdentityBlueprintListResponse>(
                new HttpRequestException("Unavailable")));
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "agent-response",
                "Research agent",
                "Provisioning",
                Guid.NewGuid(),
                DateTime.UtcNow,
                Links: null));
        var cut = Render<RegisterAgent>();

        cut.Find("#blueprint-mode").Change("CreateNew");
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#new-blueprint-display-name").Change(blueprintDisplayName);
        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.Received(1).RegisterAgentAsync(
            Arg.Is<RegisterAgentRequest>(request =>
                request.Blueprint != null &&
                request.Blueprint.Mode == "CreateNew" &&
                request.Blueprint.BlueprintObjectId == null &&
                request.Blueprint.DisplayName == blueprintDisplayName),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void ConfigurationFailure_KeepsAgent365OnAndAzureMonitorOff()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromException<SystemConfigDto>(new HttpRequestException("Unavailable")));

        var cut = Render<RegisterAgent>();

        cut.Find("#agent365-observability-enabled").HasAttribute("checked").Should().BeTrue();
        cut.Find("#azure-monitor-export-enabled").HasAttribute("checked").Should().BeFalse();
        cut.Find("[role='alert']").TextContent.Should().Contain("could not verify");
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();
    }

    [Fact]
    public async Task ProvisioningDisabled_ShowsActionableStateAndDoesNotSubmit()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(
                "Agent365",
                agent365Enabled: true,
                azureMonitorEnabled: false,
                provisioningExecutionEnabled: false));

        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Unavailable agent");

        cut.Find("[role='alert']").TextContent.Should().Contain("no open provisioning window");
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.DidNotReceive().RegisterAgentAsync(
            Arg.Any<RegisterAgentRequest>(),
            Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData("Disabled", false, false)]
    [InlineData("GatewayOnly", false, true)]
    [InlineData("Agent365", true, false)]
    [InlineData("Agent365AzureMonitor", true, true)]
    public void OmittedCanonicalSystemDefaults_FallBackToLegacyMode(
        string legacyMode,
        bool expectedAgent365,
        bool expectedAzureMonitor)
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(legacyMode, agent365Enabled: null, azureMonitorEnabled: null));

        var cut = Render<RegisterAgent>();

        cut.Find("#agent365-observability-enabled").HasAttribute("checked")
            .Should().Be(expectedAgent365);
        cut.Find("#azure-monitor-export-enabled").HasAttribute("checked")
            .Should().Be(expectedAzureMonitor);
    }

    [Theory]
    [InlineData("Agent365AzureMonitor", false, false)]
    [InlineData("GatewayOnly", true, false)]
    [InlineData("Agent365", false, true)]
    [InlineData("Disabled", true, true)]
    public void CanonicalSystemDefaults_WinOverConflictingLegacyMode(
        string legacyMode,
        bool agent365Enabled,
        bool azureMonitorEnabled)
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(legacyMode, agent365Enabled, azureMonitorEnabled));

        var cut = Render<RegisterAgent>();

        cut.Find("#agent365-observability-enabled").HasAttribute("checked")
            .Should().Be(agent365Enabled);
        cut.Find("#azure-monitor-export-enabled").HasAttribute("checked")
            .Should().Be(azureMonitorEnabled);
    }

    [Theory]
    [InlineData(true, false, "Agent365")]
    [InlineData(false, true, "GatewayOnly")]
    [InlineData(true, true, "Agent365AzureMonitor")]
    [InlineData(false, false, "Disabled")]
    public async Task IndependentObservabilityChoices_AreSubmittedWithCanonicalAndLegacyValues(
        bool agent365Enabled,
        bool azureMonitorEnabled,
        string expectedLegacyMode)
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var operationId = Guid.NewGuid();
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "agent-response",
                "Research agent",
                "Provisioning",
                operationId,
                DateTime.UtcNow,
                Links: null));
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));
        cut.Find("#agent365-observability-enabled").Change(agent365Enabled);
        cut.Find("#azure-monitor-export-enabled").Change(azureMonitorEnabled);

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.Received(1).RegisterAgentAsync(
            Arg.Is<RegisterAgentRequest>(request =>
                request.Features != null &&
                request.Features.ObservabilityMode == expectedLegacyMode &&
                request.Features.Agent365ObservabilityEnabled == agent365Enabled &&
                request.Features.AzureMonitorExportEnabled == azureMonitorEnabled &&
                request.Blueprint != null &&
                request.Blueprint.Mode == "UseExisting" &&
                request.Blueprint.BlueprintObjectId == ExistingBlueprintObjectId.ToString("D") &&
                request.Blueprint.DisplayName == null),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task CreateNewBlueprint_SubmitsDisplayNameWithoutExistingObjectId()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        const string blueprintDisplayName = "Reusable research blueprint";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "agent-response",
                "Research agent",
                "Provisioning",
                Guid.NewGuid(),
                DateTime.UtcNow,
                Links: null));
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#blueprint-mode").Change("CreateNew");
        cut.FindAll("#existing-blueprint").Should().BeEmpty();
        cut.Find("#new-blueprint-display-name").Change(blueprintDisplayName);

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.Received(1).RegisterAgentAsync(
            Arg.Is<RegisterAgentRequest>(request =>
                request.Blueprint != null &&
                request.Blueprint.Mode == "CreateNew" &&
                request.Blueprint.BlueprintObjectId == null &&
                request.Blueprint.DisplayName == blueprintDisplayName),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task EditableTextFields_BindOnInputBeforeBlurAndSubmitLatestValues()
    {
        const string signedInOwnerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        const string accountableOwnerObjectId = "f2cbd325-cc09-4885-a693-c48778b647fc";
        const string name = "Research agent";
        const string description = "Answers research questions";
        const string blueprintDisplayName = "Reusable research blueprint";
        _authorization.SetClaims(new Claim("oid", signedInOwnerObjectId));
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "agent-response",
                name,
                "Provisioning",
                Guid.NewGuid(),
                DateTime.UtcNow,
                Links: null));
        var cut = Render<RegisterAgent>();
        cut.Find("#blueprint-mode").Change("CreateNew");

        cut.Find("#agent-name").Input(name);
        cut.Find("#owner-object-id").Input(accountableOwnerObjectId);
        cut.Find("#agent-description").Input(description);
        cut.Find("#new-blueprint-display-name").Input(blueprintDisplayName);

        cut.Find(".field-counter").TextContent.Should().Be($"{description.Length} / 2,000");
        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.Received(1).RegisterAgentAsync(
            Arg.Is<RegisterAgentRequest>(request =>
                request.Name == name &&
                request.OwnerObjectId == accountableOwnerObjectId &&
                request.Description == description &&
                request.Blueprint != null &&
                request.Blueprint.Mode == "CreateNew" &&
                request.Blueprint.BlueprintObjectId == null &&
                request.Blueprint.DisplayName == blueprintDisplayName),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void GatewayCredential_IsNotRenderedBeforeRegistrationSucceeds()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));

        var cut = Render<RegisterAgent>();

        cut.FindAll("#gateway-api-key").Should().BeEmpty();
        cut.FindAll("#gateway-authorization-header").Should().BeEmpty();
        cut.FindAll("#gateway-credential-expiration").Should().BeEmpty();
        cut.FindAll("#continue-to-provisioning").Should().BeEmpty();
        cut.Markup.Should().NotContain("Authorization: Bearer");
    }

    [Fact]
    public async Task CredentialResponse_StaysOnPageAndDisplaysTheOneTimeHandoff()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        const string externalAgentId = "ext-agent-01";
        const string apiKey = "a365gw_4f3a4ecfc6f94919b66854f9f1480dd1.one-time-key-material";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var operationId = Guid.NewGuid();
        var expiresAtUtc = new DateTime(2026, 9, 25, 3, 4, 5, DateTimeKind.Utc);
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                externalAgentId,
                "Research agent",
                "Provisioning",
                operationId,
                DateTime.UtcNow,
                Links: null,
                GatewayCredential: new AgentGatewayCredentialDto(Guid.NewGuid(), apiKey, expiresAtUtc)));
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        var navigation = Services.GetRequiredService<NavigationManager>();
        navigation.Uri.Should().Be("http://localhost/");
        navigation.Uri.Should().NotContain(apiKey);
        cut.FindAll("form").Should().BeEmpty();
        cut.Find("#credential-external-agent-id").GetAttribute("value").Should().Be(externalAgentId);
        cut.Find("#gateway-api-key").GetAttribute("value").Should().Be(apiKey);
        cut.Find("#gateway-authorization-header").GetAttribute("value")
            .Should().Be($"Authorization: Bearer {apiKey}");
        var expiration = cut.Find("#gateway-credential-expiration");
        expiration.TextContent.Should().Be("2026-09-25 03:04:05 UTC");
        expiration.GetAttribute("datetime").Should().Be(expiresAtUtc.ToString("O"));
        cut.Find("[role='alert']").TextContent.Should().Contain("cannot be retrieved again");
        cut.Markup.Should().Contain("Leaving this page permanently removes it from the portal");
        cut.Find("#continue-to-provisioning").Should().NotBeNull();
    }

    [Fact]
    public async Task CredentialHandoff_RequiresExplicitContinuationBeforeProvisioningNavigation()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        const string apiKey = "a365gw_92c1863af91c4fb9b178ff578108d52c.ephemeral-material";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var operationId = Guid.NewGuid();
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "ext-agent-02",
                "Research agent",
                "Provisioning",
                operationId,
                DateTime.UtcNow,
                Links: null,
                GatewayCredential: new AgentGatewayCredentialDto(
                    Guid.NewGuid(),
                    apiKey,
                    DateTime.UtcNow.AddDays(30))));
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        var navigation = Services.GetRequiredService<NavigationManager>();
        navigation.Uri.Should().Be("http://localhost/");

        await cut.Find("#continue-to-provisioning").ClickAsync(new MouseEventArgs());

        navigation.Uri.Should().EndWith($"/operations/{operationId:D}");
        navigation.Uri.Should().NotContain(apiKey);
        cut.Markup.Should().NotContain(apiKey);
    }

    [Theory]
    [InlineData("oid")]
    [InlineData("http://schemas.microsoft.com/identity/claims/objectidentifier")]
    public async Task GeneratedIdentityAndClaimOwner_AreSubmittedOnceWhileRequestIsPending(
        string objectIdClaimType)
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim(objectIdClaimType, ownerObjectId));
        var agentId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        var completion = new TaskCompletionSource<RegisterAgentResponse>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(completion.Task);
        var cut = Render<RegisterAgent>();

        var externalAgentIdInput = cut.Find("#external-agent-id");
        var generatedExternalAgentId = externalAgentIdInput.GetAttribute("value");
        generatedExternalAgentId.Should().NotBeNullOrWhiteSpace();
        generatedExternalAgentId!.Length.Should().BeLessThanOrEqualTo(128);
        generatedExternalAgentId.Should().MatchRegex("^[a-zA-Z0-9][a-zA-Z0-9._-]*$");
        externalAgentIdInput.HasAttribute("readonly").Should().BeTrue();
        externalAgentIdInput.GetAttribute("aria-readonly").Should().Be("true");

        var ownerObjectIdInput = cut.Find("#owner-object-id");
        ownerObjectIdInput.GetAttribute("value").Should().Be(ownerObjectId);
        ownerObjectIdInput.HasAttribute("readonly").Should().BeFalse();
        ownerObjectIdInput.GetAttribute("aria-readonly").Should().BeNull();

        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));
        cut.Find("#external-agent-id").GetAttribute("value").Should().Be(generatedExternalAgentId);
        var form = cut.Find("form");

        var firstSubmission = form.SubmitAsync(EventArgs.Empty);
        cut.WaitForAssertion(() =>
        {
            _api.Received(1).RegisterAgentAsync(
                Arg.Is<RegisterAgentRequest>(request =>
                    request.Name == "Research agent" &&
                    request.ExternalAgentId == generatedExternalAgentId &&
                    request.OwnerObjectId == ownerObjectId &&
                    request.Blueprint != null &&
                    request.Blueprint.BlueprintObjectId == ExistingBlueprintObjectId.ToString("D")),
                Arg.Any<CancellationToken>());
            cut.Markup.Should().Contain("Registering…");
        });

        var duplicateSubmission = form.SubmitAsync(EventArgs.Empty);
        await duplicateSubmission.WaitAsync(TimeSpan.FromSeconds(2));

        _ = _api.Received(1).RegisterAgentAsync(
            Arg.Any<RegisterAgentRequest>(),
            Arg.Any<CancellationToken>());

        completion.SetResult(new RegisterAgentResponse(
            agentId,
            generatedExternalAgentId!,
            "Research agent",
            "Provisioning",
            operationId,
            DateTime.UtcNow,
            Links: null,
            GatewayCredential: new AgentGatewayCredentialDto(
                Guid.NewGuid(),
                "a365gw_pending-test.one-time-material",
                DateTime.UtcNow.AddDays(30))));
        await firstSubmission.WaitAsync(TimeSpan.FromSeconds(2));

        var navigation = Services.GetRequiredService<NavigationManager>();
        navigation.Uri.Should().Be("http://localhost/");
        cut.Markup.Should().Contain("Save this Gateway API key now");
    }

    [Fact]
    public async Task MissingRequiredCredential_StaysOnPageWithSafeRecoveryGuidance()
    {
        const string ownerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        _authorization.SetClaims(new Claim("oid", ownerObjectId));
        var operationId = Guid.NewGuid();
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "ext-agent-missing-credential",
                "Research agent",
                "Provisioning",
                operationId,
                DateTime.UtcNow,
                Links: null,
                GatewayCredential: null));
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        var navigation = Services.GetRequiredService<NavigationManager>();
        navigation.Uri.Should().Be("http://localhost/");
        navigation.Uri.Should().NotContain(operationId.ToString("D"));
        cut.FindAll("#gateway-api-key").Should().BeEmpty();
        var alert = cut.Find("[role='alert']").TextContent;
        alert.Should().Contain("Acceptance may already have occurred");
        alert.Should().Contain("do not submit this form again");
        alert.Should().Contain("Locate the registration in Agents");
        alert.Should().Contain("issue a replacement credential");
    }

    [Fact]
    public async Task ValidOwnerOverride_IsSubmittedInsteadOfSignedInOwner()
    {
        const string signedInOwnerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896";
        const string accountableOwnerObjectId = "f2cbd325-cc09-4885-a693-c48778b647fc";
        _authorization.SetClaims(new Claim("oid", signedInOwnerObjectId));
        var operationId = Guid.NewGuid();
        _api.RegisterAgentAsync(
                Arg.Any<RegisterAgentRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(new RegisterAgentResponse(
                Guid.NewGuid(),
                "agent-response",
                "Research agent",
                "Provisioning",
                operationId,
                DateTime.UtcNow,
                Links: null));
        var cut = Render<RegisterAgent>();
        var generatedExternalAgentId = cut.Find("#external-agent-id").GetAttribute("value");
        cut.Find("#agent-name").Change("Research agent");
        cut.Find("#owner-object-id").Change(accountableOwnerObjectId);
        cut.Find("#existing-blueprint").Change(ExistingBlueprintObjectId.ToString("D"));

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.Received(1).RegisterAgentAsync(
            Arg.Is<RegisterAgentRequest>(request =>
                request.ExternalAgentId == generatedExternalAgentId &&
                request.OwnerObjectId == accountableOwnerObjectId),
            Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-a-guid")]
    public async Task MissingOrInvalidOid_FailsClosedWithoutSubmittingOrNavigating(
        string? ownerObjectId)
    {
        _authorization.SetClaims(ownerObjectId is null
            ? []
            : [new Claim("oid", ownerObjectId)]);
        var cut = Render<RegisterAgent>();
        cut.Find("#agent-name").Change("Research agent");

        await cut.Find("form").SubmitAsync(EventArgs.Empty);

        _ = _api.DidNotReceive().RegisterAgentAsync(
            Arg.Any<RegisterAgentRequest>(),
            Arg.Any<CancellationToken>());
        cut.Find("[role='alert']").TextContent.Should().NotBeNullOrWhiteSpace();
        cut.Find("fluent-button[type='submit']").HasAttribute("disabled").Should().BeTrue();
        if (!string.IsNullOrEmpty(ownerObjectId))
        {
            cut.Markup.Should().NotContain(ownerObjectId);
        }

        var navigation = Services.GetRequiredService<NavigationManager>();
        navigation.Uri.Should().Be("http://localhost/");
    }

    private static SystemConfigDto CreateConfig(
        string legacyMode,
        bool? agent365Enabled,
        bool? azureMonitorEnabled,
        bool provisioningExecutionEnabled = true) => new(
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
        DefaultAzureMonitorExportEnabled: azureMonitorEnabled,
        ProvisioningExecutionEnabled: provisioningExecutionEnabled,
        PurviewPolicyProvisioningEnabled: true);

    private static AgentIdentityBlueprintListResponse CreateBlueprintInventory() => new(
    [
        new AgentIdentityBlueprintSummaryDto(
            ExistingBlueprintObjectId,
            ExistingBlueprintClientId,
            "Shared research blueprint",
            IsAgent365Compatible: true,
            Agent365CompatibilityIssue: null),
        new AgentIdentityBlueprintSummaryDto(
            AnalyticsBlueprintObjectId,
            AnalyticsBlueprintClientId,
            "Analytics blueprint",
            IsAgent365Compatible: true,
            Agent365CompatibilityIssue: null)
    ]);

    private static Guid LargeInventoryObjectId(int index) =>
        Guid.Parse($"0000{index:D4}-0000-4000-8000-000000000000");

    private static AgentIdentityBlueprintListResponse CreateLargeBlueprintInventory(
        int compatible,
        int incompatible)
    {
        var items = new List<AgentIdentityBlueprintSummaryDto>(compatible + incompatible);
        for (var index = 1; index <= compatible; index++)
        {
            var objectId = LargeInventoryObjectId(index);
            items.Add(new AgentIdentityBlueprintSummaryDto(
                objectId,
                objectId,
                $"Available blueprint {index:D2}",
                IsAgent365Compatible: true,
                Agent365CompatibilityIssue: null));
        }

        for (var index = 1; index <= incompatible; index++)
        {
            var objectId = LargeInventoryObjectId(1000 + index);
            items.Add(new AgentIdentityBlueprintSummaryDto(
                objectId,
                objectId,
                $"Legacy blueprint {index:D2}",
                IsAgent365Compatible: false,
                Agent365CompatibilityIssue: "MissingRequiredManagerApplications"));
        }

        return new AgentIdentityBlueprintListResponse(items);
    }
}
