using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class SetupWizardStateTests
{
    [Fact]
    public void NewConfiguration_HasNoImplicitAzureRegion()
    {
        var state = NewState();

        state.Form.Location.Should().BeEmpty();
        state.HasValidSelectedLocation.Should().BeFalse();
    }

    [Fact]
    public void ApplyLocationDiscovery_PreservesExactValidImportedSelection()
    {
        var state = NewState();
        var form = ValidForm();
        form.Location = "koreacentral";
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([
            new AzureSubscription(
                form.SubscriptionId,
                form.TenantId,
                "Imported target",
                true,
                "Enabled")
        ]);

        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            form.SubscriptionId,
            [
                new AzureLocation("eastus2", "East US 2"),
                new AzureLocation("koreacentral", "Korea Central")
            ],
            null));

        state.Form.Location.Should().Be("koreacentral");
        state.HasValidSelectedLocation.Should().BeTrue();
        state.LocationSelectionIssue.Should().BeNull();
    }

    [Fact]
    public void ApplyLocationDiscovery_BlocksUnavailableImportedSelection()
    {
        var state = NewState();
        var form = ValidForm();
        form.Location = "eastus2";
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([
            new AzureSubscription(
                form.SubscriptionId,
                form.TenantId,
                "Imported target",
                true,
                "Enabled")
        ]);

        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            form.SubscriptionId,
            [new AzureLocation("koreacentral", "Korea Central")],
            null));

        state.Form.Location.Should().Be("eastus2");
        state.HasValidSelectedLocation.Should().BeFalse();
        state.LocationSelectionIssue.Should().Contain("not available");
    }

    [Fact]
    public void SelectLocation_AcceptsOnlyExactCurrentSubscriptionInventoryValue()
    {
        var state = NewState();
        var subscription = Subscription("Target", isDefault: true, state: "Enabled");
        state.SetSubscriptions([subscription]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            subscription.SubscriptionId,
            [new AzureLocation("koreacentral", "Korea Central")],
            null));

        state.SelectLocation("KoreaCentral").Should().BeFalse();
        state.Form.Location.Should().BeEmpty();
        state.SelectLocation("koreacentral").Should().BeTrue();
        state.Form.Location.Should().Be("koreacentral");
        state.HasValidSelectedLocation.Should().BeTrue();
    }

    [Fact]
    public void FailedLocationDiscovery_ClearsInventoryAndBlocksPreviousSelection()
    {
        var state = NewState();
        var subscription = Subscription("Target", isDefault: true, state: "Enabled");
        state.SetSubscriptions([subscription]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            subscription.SubscriptionId,
            [new AzureLocation("koreacentral", "Korea Central")],
            null));
        state.SelectLocation("koreacentral").Should().BeTrue();

        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            subscription.SubscriptionId,
            [],
            "Azure CLI could not read the available Azure location inventory."));

        state.Locations.Should().BeEmpty();
        state.LocationDiscoveryGuidance.Should().NotBeNull();
        state.HasValidSelectedLocation.Should().BeFalse();
        state.SelectLocation("koreacentral").Should().BeFalse();
    }

    [Fact]
    public void ChangingSubscription_InvalidatesLocationInventoryAndSelection()
    {
        var state = NewState();
        var first = Subscription("First", isDefault: true, state: "Enabled");
        var second = Subscription("Second", isDefault: false, state: "Enabled");
        state.SetSubscriptions([first]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            first.SubscriptionId,
            [new AzureLocation("koreacentral", "Korea Central")],
            null));
        state.SelectLocation("koreacentral").Should().BeTrue();
        state.SetSubscriptions([first, second]);

        state.SelectSubscription(second.SubscriptionId).Should().BeTrue();

        state.Form.Location.Should().BeEmpty();
        state.Locations.Should().BeEmpty();
        state.HasValidSelectedLocation.Should().BeFalse();
    }

    [Fact]
    public void SelectedSubscriptionDisappearing_InvalidatesEveryPlanReadinessProof()
    {
        var state = ReadyState();

        state.SetSubscriptions([]);

        state.HasEnabledSelectedSubscription.Should().BeFalse();
        state.HasValidSelectedLocation.Should().BeFalse();
        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void SelectedSubscriptionBecomingDisabled_InvalidatesEveryPlanReadinessProof()
    {
        var state = ReadyState();
        var selected = state.Subscriptions.Single();

        state.SetSubscriptions([
            selected with { State = "Disabled" }
        ]);

        state.HasEnabledSelectedSubscription.Should().BeFalse();
        state.HasValidSelectedLocation.Should().BeFalse();
        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void ImportedManagerAcceptanceRecoversOnlyForTheSameRestoredTarget()
    {
        var state = NewState();
        var form = ValidForm();
        form.Location = "koreacentral";
        var selected = new AzureSubscription(
            form.SubscriptionId,
            form.TenantId,
            "Imported target",
            true,
            "Enabled");
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([selected]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            selected.SubscriptionId,
            [new AzureLocation("koreacentral", "Korea Central")],
            null));
        state.ManagerApplicationsAccepted.Should().BeTrue();

        state.SetSubscriptions([]);
        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.SetSubscriptions([selected]);

        state.ManagerApplicationsAccepted.Should().BeTrue();
        state.HasValidSelectedLocation.Should().BeFalse(
            "a restored subscription still requires fresh location inventory");
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void SetSubscriptions_WithMultipleEnabledTargets_RequiresExplicitSelection()
    {
        var state = NewState();
        var cliDefault = Subscription("CLI default", isDefault: true, state: "Enabled");
        var other = Subscription("Other", isDefault: false, state: "Enabled");

        state.SetSubscriptions([cliDefault, other]);

        state.EnabledSubscriptionCount.Should().Be(2);
        state.Form.SubscriptionId.Should().Be(Guid.Empty);
        state.Form.TenantId.Should().Be(Guid.Empty);
        state.HasEnabledSelectedSubscription.Should().BeFalse();
        state.AccountSelectionIssue.Should().BeNull();
    }

    [Fact]
    public void SetSubscriptions_WithOneEnabledTarget_SelectsOnlyThatTarget()
    {
        var state = NewState();
        var disabledDefault = Subscription("Disabled default", isDefault: true, state: "Disabled");
        var enabled = Subscription("Enabled target", isDefault: false, state: "Enabled");

        state.SetSubscriptions([disabledDefault, enabled]);

        state.Form.SubscriptionId.Should().Be(enabled.SubscriptionId);
        state.Form.TenantId.Should().Be(enabled.TenantId);
        state.HasEnabledSelectedSubscription.Should().BeTrue();
        state.AccountSelectionIssue.Should().BeNull();
    }

    [Fact]
    public void SelectSubscription_RejectsDisabledTarget()
    {
        var state = NewState();
        var enabled = Subscription("Enabled", isDefault: false, state: "Enabled");
        var disabled = Subscription("Disabled", isDefault: true, state: "Disabled");
        state.SetSubscriptions([enabled, disabled]);

        var selected = state.SelectSubscription(disabled.SubscriptionId);

        selected.Should().BeFalse();
        state.Form.SubscriptionId.Should().Be(enabled.SubscriptionId);
        state.Form.TenantId.Should().Be(enabled.TenantId);
    }

    [Fact]
    public void ImportedDisabledTarget_RemainsLockedAndBlocksContinuation()
    {
        var state = NewState();
        var form = ValidForm();
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));

        state.SetSubscriptions([
            new AzureSubscription(
                form.SubscriptionId,
                form.TenantId,
                "Imported target",
                true,
                "Disabled")
        ]);

        state.Form.SubscriptionId.Should().Be(form.SubscriptionId);
        state.HasEnabledSelectedSubscription.Should().BeFalse();
        state.AccountSelectionIssue.Should().Contain("not Enabled");
        state.SelectSubscription(form.SubscriptionId).Should().BeFalse();
    }

    [Fact]
    public void AcceptDiscoveredManagerApplications_PopulatesExactSortedSetOnlyAfterAcceptance()
    {
        var state = NewState();
        var subscription = Subscription("Target", isDefault: true, state: "Enabled");
        var higher = Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
        var lower = Guid.Parse("11111111-1111-4111-8111-111111111111");
        state.SetSubscriptions([subscription]);
        state.BeginManagerApplicationDiscovery();
        state.ApplyManagerApplicationDiscovery(new ManagerApplicationDiscoveryResult(
            subscription.SubscriptionId,
            subscription.TenantId,
            [Candidate(higher), Candidate(lower)],
            AzureAccountDiscovery.ManagerApplicationProvenance,
            null));

        state.Form.ReviewedManagerApplicationIds.Should().BeEmpty();
        state.ManagerApplicationsAccepted.Should().BeFalse();

        state.AcceptDiscoveredManagerApplications().Should().BeTrue();
        state.ManagerApplicationsAccepted.Should().BeTrue();
        state.Form.GetReviewedManagerApplicationIds().Should().Equal(lower, higher);
    }

    [Fact]
    public void ChangingSubscription_InvalidatesManagerApplicationAcceptance()
    {
        var state = NewState();
        var first = Subscription("First", isDefault: true, state: "Enabled");
        var second = Subscription("Second", isDefault: false, state: "Enabled");
        state.SetSubscriptions([first]);
        state.ApplyManagerApplicationDiscovery(new ManagerApplicationDiscoveryResult(
            first.SubscriptionId,
            first.TenantId,
            [Candidate(Guid.NewGuid())],
            AzureAccountDiscovery.ManagerApplicationProvenance,
            null));
        state.AcceptDiscoveredManagerApplications().Should().BeTrue();
        state.SetSubscriptions([first, second]);

        state.SelectSubscription(second.SubscriptionId).Should().BeTrue();

        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.Form.ReviewedManagerApplicationIds.Should().BeEmpty();
        state.ManagerApplicationCandidates.Should().BeEmpty();
    }

    [Fact]
    public void ManagerApplicationAcceptance_BecomesStaleWhenReviewedValuesChange()
    {
        var state = ReadyState();

        state.Form.ReviewedManagerApplicationIds = Guid.NewGuid().ToString("D");

        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void PlanReadiness_RequiresExactCurrentLocationInventoryMembership()
    {
        var state = ReadyState();
        state.Form.Location = "eastus2";

        state.HasValidSelectedLocation.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void PurviewDisabled_DoesNotBlockOtherwiseReadyCorePlan()
    {
        var state = ReadyState();

        state.Form.PurviewEnabled.Should().BeFalse();
        state.HasValidPurviewSensitiveInformationTypeSelection.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeTrue();
    }

    [Fact]
    public void EnablingPurview_HasNoImplicitSensitiveInformationTypeSelection()
    {
        var state = ReadyState();

        state.SetPurviewEnabled(true).Should().BeTrue();

        state.Form.PurviewSensitiveInformationTypeId.Should().Be(Guid.Empty);
        state.Form.PurviewSensitiveInformationType.Should().BeEmpty();
        state.PurviewSensitiveInformationTypes.Should().BeEmpty();
        state.HasValidPurviewSensitiveInformationTypeSelection.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void SelectPurviewSensitiveInformationType_StoresExactGuidAndUnicodeName()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var type = SensitiveInformationType("주민등록번호", "Contoso");
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [type]));

        state.SelectPurviewSensitiveInformationType(type.Id).Should().BeTrue();

        state.Form.PurviewSensitiveInformationTypeId.Should().Be(type.Id);
        state.Form.PurviewSensitiveInformationType.Should().Be("주민등록번호");
        state.HasValidPurviewSensitiveInformationTypeSelection.Should().BeTrue();
        state.CanWriteConfigurationAndRunPlan.Should().BeTrue();
    }

    [Fact]
    public void PurviewSelection_IsKeyedByGuidAndRequiresExactCurrentName()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var first = SensitiveInformationType("Duplicate name", "Microsoft");
        var second = SensitiveInformationType("duplicate name", "Contoso");
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [first, second]));
        state.SelectPurviewSensitiveInformationType(second.Id).Should().BeTrue();

        state.Form.PurviewSensitiveInformationType = "Duplicate name";

        state.HasValidPurviewSensitiveInformationTypeSelection.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void DuplicateExactPurviewNamesInvalidateInventoryProof()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var first = SensitiveInformationType("Credit Card Number", "Microsoft");
        var second = SensitiveInformationType("Credit Card Number", "Contoso");

        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [first, second]));

        state.PurviewSensitiveInformationTypes.Should().BeEmpty();
        state.PurviewSensitiveInformationTypeDiscoveryGuidance.Should().Contain("unexpected");
        state.HasValidPurviewSensitiveInformationTypeSelection.Should().BeFalse();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void FailedPurviewRefresh_InvalidatesProofAndClearsFreshSelection()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var type = SensitiveInformationType("Credit Card Number", "Microsoft Corporation");
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [type]));
        state.SelectPurviewSensitiveInformationType(type.Id).Should().BeTrue();

        state.BeginPurviewSensitiveInformationTypeDiscovery();
        state.ApplyPurviewSensitiveInformationTypeDiscovery(new(
            state.Form.SubscriptionId,
            state.Form.TenantId,
            [],
            PurviewSensitiveInformationTypeDiscovery.Provenance,
            "Purview inventory could not be read."));

        state.PurviewSensitiveInformationTypes.Should().BeEmpty();
        state.Form.PurviewSensitiveInformationTypeId.Should().Be(Guid.Empty);
        state.Form.PurviewSensitiveInformationType.Should().BeEmpty();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void DisablingPurview_InvalidatesInventoryAndClearsFreshSelectionWithoutBlockingCore()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var type = SensitiveInformationType("Credit Card Number", "Microsoft Corporation");
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [type]));
        state.SelectPurviewSensitiveInformationType(type.Id).Should().BeTrue();

        state.SetPurviewEnabled(false).Should().BeTrue();

        state.PurviewSensitiveInformationTypes.Should().BeEmpty();
        state.Form.PurviewSensitiveInformationTypeId.Should().Be(Guid.Empty);
        state.Form.PurviewSensitiveInformationType.Should().BeEmpty();
        state.CanWriteConfigurationAndRunPlan.Should().BeTrue();
    }

    [Fact]
    public void PurviewDiscoveryForWrongTarget_IsRejectedAndClearsFreshSelection()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var type = SensitiveInformationType("Credit Card Number", "Microsoft Corporation");
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [type]));
        state.SelectPurviewSensitiveInformationType(type.Id).Should().BeTrue();

        state.ApplyPurviewSensitiveInformationTypeDiscovery(new(
            Guid.NewGuid(),
            Guid.NewGuid(),
            [type],
            PurviewSensitiveInformationTypeDiscovery.Provenance,
            null));

        state.PurviewSensitiveInformationTypes.Should().BeEmpty();
        state.Form.PurviewSensitiveInformationTypeId.Should().Be(Guid.Empty);
        state.Form.PurviewSensitiveInformationType.Should().BeEmpty();
        state.PurviewSensitiveInformationTypeDiscoveryGuidance.Should().Contain("changed");
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void ChangingSubscription_InvalidatesPurviewInventoryAndFreshSelection()
    {
        var state = ReadyState();
        state.SetPurviewEnabled(true).Should().BeTrue();
        var type = SensitiveInformationType("Credit Card Number", "Microsoft Corporation");
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [type]));
        state.SelectPurviewSensitiveInformationType(type.Id).Should().BeTrue();
        var current = state.Subscriptions.Single();
        var replacement = Subscription("Replacement", isDefault: false, state: "Enabled");
        state.SetSubscriptions([current, replacement]);

        state.SelectSubscription(replacement.SubscriptionId).Should().BeTrue();

        state.PurviewSensitiveInformationTypes.Should().BeEmpty();
        state.Form.PurviewSensitiveInformationTypeId.Should().Be(Guid.Empty);
        state.Form.PurviewSensitiveInformationType.Should().BeEmpty();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void ImportedEnabledPurview_RemainsLockedButNeedsFreshExactProof()
    {
        var state = NewState();
        var form = ValidForm();
        form.Location = "koreacentral";
        form.PurviewEnabled = true;
        var type = SensitiveInformationType("주민등록번호", "Contoso");
        form.PurviewSensitiveInformationTypeId = type.Id;
        form.PurviewSensitiveInformationType = type.Name;
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([
            new AzureSubscription(
                form.SubscriptionId,
                form.TenantId,
                "Imported target",
                true,
                "Enabled")
        ]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            form.SubscriptionId,
            [new AzureLocation(form.Location, "Korea Central")],
            null));

        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(state, [type]));

        state.Form.PurviewSensitiveInformationTypeId.Should().Be(type.Id);
        state.Form.PurviewSensitiveInformationType.Should().Be(type.Name);
        state.HasValidPurviewSensitiveInformationTypeSelection.Should().BeTrue();
        state.CanWriteConfigurationAndRunPlan.Should().BeTrue();
        state.SelectPurviewSensitiveInformationType(Guid.NewGuid()).Should().BeFalse();
    }

    [Fact]
    public void ImportedEnabledPurview_NameDriftPreservesLockedValuesAndBlocksPlan()
    {
        var state = NewState();
        var form = ValidForm();
        form.Location = "koreacentral";
        form.PurviewEnabled = true;
        var imported = SensitiveInformationType("Original exact name", "Contoso");
        form.PurviewSensitiveInformationTypeId = imported.Id;
        form.PurviewSensitiveInformationType = imported.Name;
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([
            new AzureSubscription(form.SubscriptionId, form.TenantId, "Imported", true, "Enabled")
        ]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            form.SubscriptionId,
            [new AzureLocation(form.Location, "Korea Central")],
            null));

        state.ApplyPurviewSensitiveInformationTypeDiscovery(PurviewResult(
            state,
            [imported with { Name = "Renamed in tenant" }]));

        state.Form.PurviewSensitiveInformationTypeId.Should().Be(imported.Id);
        state.Form.PurviewSensitiveInformationType.Should().Be("Original exact name");
        state.PurviewSensitiveInformationTypeSelectionIssue.Should().Contain("exact name");
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
    }

    [Fact]
    public void DiscoveryForStaleTarget_IsRejectedWithoutCopyingIds()
    {
        var state = NewState();
        var current = Subscription("Current", isDefault: true, state: "Enabled");
        state.SetSubscriptions([current]);

        state.ApplyManagerApplicationDiscovery(new ManagerApplicationDiscoveryResult(
            Guid.NewGuid(),
            Guid.NewGuid(),
            [Candidate(Guid.NewGuid())],
            AzureAccountDiscovery.ManagerApplicationProvenance,
            null));

        state.ManagerApplicationCandidates.Should().BeEmpty();
        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.Form.ReviewedManagerApplicationIds.Should().BeEmpty();
        state.ManagerApplicationDiscoveryGuidance.Should().Contain("changed during discovery");
    }

    [Fact]
    public void AcceptDiscoveredManagerApplications_RejectsAmbiguousDuplicateCandidates()
    {
        var state = NewState();
        var subscription = Subscription("Target", isDefault: true, state: "Enabled");
        var duplicateId = Guid.NewGuid();
        state.SetSubscriptions([subscription]);
        state.ApplyManagerApplicationDiscovery(new ManagerApplicationDiscoveryResult(
            subscription.SubscriptionId,
            subscription.TenantId,
            [Candidate(duplicateId), Candidate(duplicateId)],
            AzureAccountDiscovery.ManagerApplicationProvenance,
            null));

        state.AcceptDiscoveredManagerApplications().Should().BeFalse();
        state.ManagerApplicationsAccepted.Should().BeFalse();
        state.Form.ReviewedManagerApplicationIds.Should().BeEmpty();
    }

    [Fact]
    public void QuickDevelopmentProfile_NeverSilentlyEnablesRegistryPreview()
    {
        var form = ValidForm();
        form.AllowDevelopmentRegistryPreview = true;

        form.ApplyProfile(DeploymentProfile.StagingFoundation);
        form.ApplyProfile(DeploymentProfile.QuickDevelopment);

        form.AllowDevelopmentRegistryPreview.Should().BeFalse();
        form.Environment.Should().Be("dev");
    }

    private static SetupWizardState NewState() => new(new FixedProjectNameGenerator());

    private static SetupWizardState ReadyState()
    {
        var state = NewState();
        var subscription = Subscription("Target", isDefault: true, state: "Enabled");
        state.SetSubscriptions([subscription]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            subscription.SubscriptionId,
            [new AzureLocation("koreacentral", "Korea Central")],
            null));
        state.SelectLocation("koreacentral").Should().BeTrue();
        state.ApplyManagerApplicationDiscovery(new ManagerApplicationDiscoveryResult(
            subscription.SubscriptionId,
            subscription.TenantId,
            [Candidate(Guid.NewGuid())],
            AzureAccountDiscovery.ManagerApplicationProvenance,
            null));
        state.AcceptDiscoveredManagerApplications().Should().BeTrue();
        state.Form.AlertEmail = "operator@example.com";
        return state;
    }

    private static AzureSubscription Subscription(string name, bool isDefault, string state) =>
        new(Guid.NewGuid(), Guid.NewGuid(), name, isDefault, state);

    private static ManagerApplicationCandidate Candidate(Guid applicationId) => new(
        applicationId,
        Guid.NewGuid(),
        "Microsoft manager application",
        "Microsoft",
        "Microsoft",
        "Application",
        1,
        ["Existing blueprint"]);

    private static PurviewSensitiveInformationType SensitiveInformationType(
        string name,
        string publisher) => new(Guid.NewGuid(), name, publisher);

    private static PurviewSensitiveInformationTypeDiscoveryResult PurviewResult(
        SetupWizardState state,
        IReadOnlyList<PurviewSensitiveInformationType> types) => new(
            state.Form.SubscriptionId,
            state.Form.TenantId,
            types,
            PurviewSensitiveInformationTypeDiscovery.Provenance,
            null);

    private static SetupConfigurationForm ValidForm() => new()
    {
        SubscriptionId = Guid.NewGuid(),
        TenantId = Guid.NewGuid(),
        AlertEmail = "operator@example.com",
        ReviewedManagerApplicationIds = "33333333-3333-4333-8333-333333333333"
    };

    private sealed class FixedProjectNameGenerator : IProjectNameGenerator
    {
        public string Create() => "gwfixed";
    }
}
