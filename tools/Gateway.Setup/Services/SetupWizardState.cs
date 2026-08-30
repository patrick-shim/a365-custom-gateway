using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed class SetupWizardState
{
    private readonly object sync = new();
    private IReadOnlyList<AzureSubscription> subscriptions = [];
    private IReadOnlyList<ManagerApplicationCandidate> managerApplicationCandidates = [];
    private Guid managerApplicationDiscoverySubscriptionId;
    private Guid managerApplicationDiscoveryTenantId;
    private Guid acceptedManagerApplicationSubscriptionId;
    private Guid acceptedManagerApplicationTenantId;
    private bool managerApplicationsAccepted;
    private string? managerApplicationDiscoveryGuidance;
    private string? managerApplicationProvenance;

    public SetupWizardState(IProjectNameGenerator projectNameGenerator)
    {
        Form = new SetupConfigurationForm();
        Form.ApplyProjectName(projectNameGenerator.Create());
    }

    public SetupConfigurationForm Form { get; private set; }

    public IReadOnlyList<AzureSubscription> Subscriptions
    {
        get
        {
            lock (sync)
            {
                return subscriptions;
            }
        }
    }

    public bool ConfigurationWritten { get; private set; }

    public string? ConfigurationPath { get; private set; }

    public bool WelcomeAccepted { get; private set; }

    public bool ExistingConfigurationChecked { get; private set; }

    public bool ExistingConfigurationLoaded { get; private set; }

    public string? ExistingConfigurationGuidance { get; private set; }

    public string? AccountSelectionIssue { get; private set; }

    public int EnabledSubscriptionCount
    {
        get
        {
            lock (sync)
            {
                return subscriptions.Count(subscription =>
                    AzureAccountDiscovery.IsEnabled(subscription.State));
            }
        }
    }

    public bool HasEnabledSelectedSubscription
    {
        get
        {
            lock (sync)
            {
                return subscriptions.Any(subscription =>
                    subscription.SubscriptionId == Form.SubscriptionId &&
                    subscription.TenantId == Form.TenantId &&
                    AzureAccountDiscovery.IsEnabled(subscription.State));
            }
        }
    }

    public IReadOnlyList<ManagerApplicationCandidate> ManagerApplicationCandidates
    {
        get
        {
            lock (sync)
            {
                return managerApplicationCandidates;
            }
        }
    }

    public string? ManagerApplicationDiscoveryGuidance
    {
        get
        {
            lock (sync)
            {
                return managerApplicationDiscoveryGuidance;
            }
        }
    }

    public string? ManagerApplicationProvenance
    {
        get
        {
            lock (sync)
            {
                return managerApplicationProvenance;
            }
        }
    }

    public bool ManagerApplicationsAccepted
    {
        get
        {
            lock (sync)
            {
                return managerApplicationsAccepted &&
                    acceptedManagerApplicationSubscriptionId == Form.SubscriptionId &&
                    acceptedManagerApplicationTenantId == Form.TenantId;
            }
        }
    }

    public void AcceptWelcome() => WelcomeAccepted = true;

    public void ApplyExistingConfiguration(ExistingConfigurationResult result)
    {
        ExistingConfigurationChecked = true;
        ExistingConfigurationLoaded = result.Status == ExistingConfigurationStatus.Loaded;
        ExistingConfigurationGuidance = result.Guidance;
        if (result.Form is not null)
        {
            Form = result.Form;
            ConfigurationWritten = true;
            lock (sync)
            {
                managerApplicationsAccepted = true;
                acceptedManagerApplicationSubscriptionId = Form.SubscriptionId;
                acceptedManagerApplicationTenantId = Form.TenantId;
                managerApplicationProvenance =
                    "Imported from the existing locked bootstrap/config.json after safe schema validation";
            }
        }
    }

    public void SetSubscriptions(IReadOnlyList<AzureSubscription> discovered)
    {
        lock (sync)
        {
            subscriptions = discovered.ToArray();
        }

        AzureSubscription? selected;
        if (Form.SubscriptionId != Guid.Empty)
        {
            selected = discovered.FirstOrDefault(subscription =>
                subscription.SubscriptionId == Form.SubscriptionId &&
                subscription.TenantId == Form.TenantId);
            if (selected is null)
            {
                AccountSelectionIssue =
                    "The subscription recorded in bootstrap/config.json is not available in the current Azure CLI session. " +
                    "Sign in to that exact tenant/subscription; Setup will not silently switch the deployment target.";
                return;
            }

            if (!AzureAccountDiscovery.IsEnabled(selected.State))
            {
                AccountSelectionIssue =
                    "The exact subscription is present in Azure CLI but is not Enabled. " +
                    "Setup will not deploy to a disabled or unavailable subscription.";
                return;
            }
        }
        else
        {
            var enabled = discovered
                .Where(subscription => AzureAccountDiscovery.IsEnabled(subscription.State))
                .ToArray();
            selected = enabled.Length == 1 ? enabled[0] : null;
            if (enabled.Length == 0)
            {
                Form.ClearSubscription();
                AccountSelectionIssue =
                    "No enabled Azure subscription is available in the current CLI session.";
                return;
            }

            if (enabled.Length > 1)
            {
                Form.ClearSubscription();
                AccountSelectionIssue = null;
                return;
            }
        }

        if (selected is not null)
        {
            Form.SelectSubscription(selected);
            AccountSelectionIssue = null;
        }
    }

    public bool SelectSubscription(Guid subscriptionId)
    {
        if (ExistingConfigurationLoaded)
        {
            return false;
        }

        var subscription = Subscriptions.FirstOrDefault(item => item.SubscriptionId == subscriptionId);
        if (subscription is null || !AzureAccountDiscovery.IsEnabled(subscription.State))
        {
            return false;
        }

        var targetChanged =
            Form.SubscriptionId != subscription.SubscriptionId ||
            Form.TenantId != subscription.TenantId;
        Form.SelectSubscription(subscription);
        AccountSelectionIssue = null;
        if (targetChanged)
        {
            ResetManagerApplicationReview(clearForm: true);
        }

        return true;
    }

    public void BeginManagerApplicationDiscovery()
    {
        if (ExistingConfigurationLoaded)
        {
            return;
        }

        ResetManagerApplicationReview(clearForm: true);
    }

    public void ApplyManagerApplicationDiscovery(ManagerApplicationDiscoveryResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        lock (sync)
        {
            managerApplicationsAccepted = false;
            acceptedManagerApplicationSubscriptionId = Guid.Empty;
            acceptedManagerApplicationTenantId = Guid.Empty;
            Form.ClearReviewedManagerApplicationIds();

            if (result.SubscriptionId != Form.SubscriptionId || result.TenantId != Form.TenantId)
            {
                managerApplicationCandidates = [];
                managerApplicationDiscoverySubscriptionId = Guid.Empty;
                managerApplicationDiscoveryTenantId = Guid.Empty;
                managerApplicationProvenance = null;
                managerApplicationDiscoveryGuidance =
                    "The selected subscription changed during discovery. Review the new target and run discovery again.";
                return;
            }

            managerApplicationCandidates = result.Candidates.ToArray();
            managerApplicationDiscoverySubscriptionId = result.SubscriptionId;
            managerApplicationDiscoveryTenantId = result.TenantId;
            managerApplicationProvenance = result.Provenance;
            managerApplicationDiscoveryGuidance = result.Guidance;
        }
    }

    public bool AcceptDiscoveredManagerApplications()
    {
        lock (sync)
        {
            if (ExistingConfigurationLoaded ||
                managerApplicationDiscoveryGuidance is not null ||
                managerApplicationCandidates.Count is < 1 or > 10 ||
                managerApplicationCandidates.Any(candidate =>
                    candidate.ApplicationId == Guid.Empty ||
                    candidate.ServicePrincipalObjectId == Guid.Empty) ||
                managerApplicationCandidates
                    .Select(candidate => candidate.ApplicationId)
                    .Distinct()
                    .Count() != managerApplicationCandidates.Count ||
                managerApplicationDiscoverySubscriptionId != Form.SubscriptionId ||
                managerApplicationDiscoveryTenantId != Form.TenantId ||
                !subscriptions.Any(subscription =>
                    subscription.SubscriptionId == Form.SubscriptionId &&
                    subscription.TenantId == Form.TenantId &&
                    AzureAccountDiscovery.IsEnabled(subscription.State)))
            {
                return false;
            }

            Form.SetReviewedManagerApplicationIds(
                managerApplicationCandidates.Select(candidate => candidate.ApplicationId));
            managerApplicationsAccepted = true;
            acceptedManagerApplicationSubscriptionId = Form.SubscriptionId;
            acceptedManagerApplicationTenantId = Form.TenantId;
            return true;
        }
    }

    public void MarkConfigurationWritten(string path)
    {
        ConfigurationWritten = true;
        ConfigurationPath = path;
    }

    private void ResetManagerApplicationReview(bool clearForm)
    {
        lock (sync)
        {
            managerApplicationCandidates = [];
            managerApplicationDiscoverySubscriptionId = Guid.Empty;
            managerApplicationDiscoveryTenantId = Guid.Empty;
            acceptedManagerApplicationSubscriptionId = Guid.Empty;
            acceptedManagerApplicationTenantId = Guid.Empty;
            managerApplicationsAccepted = false;
            managerApplicationDiscoveryGuidance = null;
            managerApplicationProvenance = null;
            if (clearForm)
            {
                Form.ClearReviewedManagerApplicationIds();
            }
        }
    }
}
