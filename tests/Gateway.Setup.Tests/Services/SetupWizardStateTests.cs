using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class SetupWizardStateTests
{
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
