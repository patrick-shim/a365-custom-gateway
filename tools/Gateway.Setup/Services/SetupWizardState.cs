using System.ComponentModel.DataAnnotations;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed class SetupWizardState
{
    private readonly object sync = new();
    private IReadOnlyList<AzureSubscription> subscriptions = [];
    private IReadOnlyList<AzureLocation> locations = [];
    private Guid locationDiscoverySubscriptionId;
    private Guid locationDiscoveryTenantId;
    private string? locationDiscoveryGuidance;
    private string? locationSelectionIssue;
    private IReadOnlyList<ManagerApplicationCandidate> managerApplicationCandidates = [];
    private Guid managerApplicationDiscoverySubscriptionId;
    private Guid managerApplicationDiscoveryTenantId;
    private Guid acceptedManagerApplicationSubscriptionId;
    private Guid acceptedManagerApplicationTenantId;
    private string? acceptedManagerApplicationIds;
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

    public IReadOnlyList<AzureLocation> Locations
    {
        get
        {
            lock (sync)
            {
                return locations;
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

    public string? LocationDiscoveryGuidance
    {
        get
        {
            lock (sync)
            {
                return locationDiscoveryGuidance;
            }
        }
    }

    public string? LocationSelectionIssue
    {
        get
        {
            lock (sync)
            {
                return locationSelectionIssue;
            }
        }
    }

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
                return HasEnabledSelectedSubscriptionUnsafe();
            }
        }
    }

    public bool HasCurrentLocationInventory
    {
        get
        {
            lock (sync)
            {
                return HasCurrentLocationInventoryUnsafe();
            }
        }
    }

    public bool HasValidSelectedLocation
    {
        get
        {
            lock (sync)
            {
                return HasValidSelectedLocationUnsafe();
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
                return ManagerApplicationsAcceptedUnsafe();
            }
        }
    }

    public bool CanWriteConfigurationAndRunPlan
    {
        get
        {
            lock (sync)
            {
                return CanWriteConfigurationAndRunPlanUnsafe();
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
                ResetLocationDiscoveryUnsafe(clearForm: false);
                managerApplicationsAccepted = true;
                acceptedManagerApplicationSubscriptionId = Form.SubscriptionId;
                acceptedManagerApplicationTenantId = Form.TenantId;
                acceptedManagerApplicationIds = Form.ReviewedManagerApplicationIds;
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
                if (!ExistingConfigurationLoaded)
                {
                    ResetManagerApplicationReview(clearForm: true);
                }
                ResetLocationDiscovery(clearForm: !ExistingConfigurationLoaded);
                AccountSelectionIssue =
                    "The subscription recorded in bootstrap/config.json is not available in the current Azure CLI session. " +
                    "Sign in to that exact tenant/subscription; Setup will not silently switch the deployment target.";
                return;
            }

            if (!AzureAccountDiscovery.IsEnabled(selected.State))
            {
                if (!ExistingConfigurationLoaded)
                {
                    ResetManagerApplicationReview(clearForm: true);
                }
                ResetLocationDiscovery(clearForm: !ExistingConfigurationLoaded);
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
                ResetManagerApplicationReview(clearForm: true);
                ResetLocationDiscovery(clearForm: true);
                AccountSelectionIssue =
                    "No enabled Azure subscription is available in the current CLI session.";
                return;
            }

            if (enabled.Length > 1)
            {
                Form.ClearSubscription();
                ResetManagerApplicationReview(clearForm: true);
                ResetLocationDiscovery(clearForm: true);
                AccountSelectionIssue = null;
                return;
            }
        }

        if (selected is not null)
        {
            var targetChanged =
                Form.SubscriptionId != selected.SubscriptionId ||
                Form.TenantId != selected.TenantId;
            Form.SelectSubscription(selected);
            AccountSelectionIssue = null;
            if (targetChanged)
            {
                ResetLocationDiscovery(clearForm: !ExistingConfigurationLoaded);
            }
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
            ResetLocationDiscovery(clearForm: true);
        }

        return true;
    }

    public void BeginLocationDiscovery()
    {
        lock (sync)
        {
            ResetLocationDiscoveryUnsafe(clearForm: false);
        }
    }

    public void ApplyLocationDiscovery(AzureLocationDiscoveryResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        lock (sync)
        {
            locations = [];
            locationDiscoverySubscriptionId = result.SubscriptionId;
            locationDiscoveryTenantId = Form.TenantId;
            locationDiscoveryGuidance = result.Guidance;
            locationSelectionIssue = null;

            if (result.SubscriptionId != Form.SubscriptionId)
            {
                locationDiscoverySubscriptionId = Guid.Empty;
                locationDiscoveryTenantId = Guid.Empty;
                locationDiscoveryGuidance =
                    "The selected subscription changed while regions were loading. Reload the current subscription's regions.";
                if (!ExistingConfigurationLoaded)
                {
                    Form.ClearLocation();
                }

                return;
            }

            if (!result.Succeeded)
            {
                return;
            }

            locations = result.Locations.ToArray();
            var selectionIsValid = locations.Any(location =>
                string.Equals(location.Name, Form.Location, StringComparison.Ordinal));
            if (selectionIsValid)
            {
                return;
            }

            if (ExistingConfigurationLoaded && !string.IsNullOrWhiteSpace(Form.Location))
            {
                locationSelectionIssue =
                    $"The imported Azure region '{Form.Location}' is not available in the exact selected subscription. " +
                    "Setup will not substitute another region.";
                return;
            }

            Form.ClearLocation();
        }
    }

    public bool SelectLocation(string? locationName)
    {
        if (ExistingConfigurationLoaded)
        {
            return false;
        }

        lock (sync)
        {
            if (locationDiscoveryGuidance is not null ||
                locationDiscoverySubscriptionId != Form.SubscriptionId ||
                locationDiscoveryTenantId != Form.TenantId)
            {
                return false;
            }

            var location = locations.FirstOrDefault(candidate =>
                string.Equals(candidate.Name, locationName, StringComparison.Ordinal));
            if (location is null)
            {
                return false;
            }

            Form.SelectLocation(location);
            locationSelectionIssue = null;
            return true;
        }
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
            acceptedManagerApplicationIds = Form.ReviewedManagerApplicationIds;
            return true;
        }
    }

    public PlanReadyConfiguration CreatePlanReadyConfiguration()
    {
        lock (sync)
        {
            if (!CanWriteConfigurationAndRunPlanUnsafe())
            {
                throw new ValidationException(
                    "The selected subscription, Azure region, or Agent 365 manager review is no longer current. Return to Profile, refresh the exact target inventory, and review it again before Plan.");
            }

            var validationResults = new List<ValidationResult>();
            if (!Validator.TryValidateObject(
                    Form,
                    new ValidationContext(Form),
                    validationResults,
                    validateAllProperties: true))
            {
                var message = string.Join(
                    " ",
                    validationResults.Select(result => result.ErrorMessage));
                throw new ValidationException(message);
            }

            return CreatePlanReadyConfigurationUnsafe();
        }
    }

    public bool IsPlanReadinessCurrent(PlanReadinessToken readiness)
    {
        ArgumentNullException.ThrowIfNull(readiness);
        lock (sync)
        {
            if (!CanWriteConfigurationAndRunPlanUnsafe())
            {
                return false;
            }

            var current = CreatePlanReadyConfigurationUnsafe();
            return string.Equals(
                readiness.ConfigurationFingerprint,
                current.Readiness.ConfigurationFingerprint,
                StringComparison.Ordinal);
        }
    }

    public void MarkConfigurationWritten(string path)
    {
        lock (sync)
        {
            ConfigurationWritten = true;
            ConfigurationPath = path;
        }
    }

    private PlanReadyConfiguration CreatePlanReadyConfigurationUnsafe()
    {
        var configuration = BootstrapConfiguration.From(Form);
        var serializedJson = BootstrapConfigurationDocument.Serialize(configuration);
        return new PlanReadyConfiguration(
            configuration,
            serializedJson,
            new PlanReadinessToken(
                BootstrapConfigurationDocument.Fingerprint(serializedJson)));
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
            acceptedManagerApplicationIds = null;
            managerApplicationsAccepted = false;
            managerApplicationDiscoveryGuidance = null;
            managerApplicationProvenance = null;
            if (clearForm)
            {
                Form.ClearReviewedManagerApplicationIds();
            }
        }
    }

    private void ResetLocationDiscovery(bool clearForm)
    {
        lock (sync)
        {
            ResetLocationDiscoveryUnsafe(clearForm);
        }
    }

    private void ResetLocationDiscoveryUnsafe(bool clearForm)
    {
        locations = [];
        locationDiscoverySubscriptionId = Guid.Empty;
        locationDiscoveryTenantId = Guid.Empty;
        locationDiscoveryGuidance = null;
        locationSelectionIssue = null;
        if (clearForm)
        {
            Form.ClearLocation();
        }
    }

    private bool HasEnabledSelectedSubscriptionUnsafe() =>
        AccountSelectionIssue is null &&
        subscriptions.Any(subscription =>
            subscription.SubscriptionId == Form.SubscriptionId &&
            subscription.TenantId == Form.TenantId &&
            AzureAccountDiscovery.IsEnabled(subscription.State));

    private bool HasCurrentLocationInventoryUnsafe() =>
        locationDiscoveryGuidance is null &&
        locations.Count > 0 &&
        locationDiscoverySubscriptionId == Form.SubscriptionId &&
        locationDiscoveryTenantId == Form.TenantId;

    private bool HasValidSelectedLocationUnsafe() =>
        HasCurrentLocationInventoryUnsafe() &&
        locationSelectionIssue is null &&
        locations.Any(location =>
            string.Equals(location.Name, Form.Location, StringComparison.Ordinal));

    private bool ManagerApplicationsAcceptedUnsafe() =>
        managerApplicationsAccepted &&
        HasEnabledSelectedSubscriptionUnsafe() &&
        acceptedManagerApplicationSubscriptionId == Form.SubscriptionId &&
        acceptedManagerApplicationTenantId == Form.TenantId &&
        acceptedManagerApplicationIds is not null &&
        string.Equals(
            acceptedManagerApplicationIds,
            Form.ReviewedManagerApplicationIds,
            StringComparison.Ordinal);

    private bool CanWriteConfigurationAndRunPlanUnsafe() =>
        HasEnabledSelectedSubscriptionUnsafe() &&
        HasValidSelectedLocationUnsafe() &&
        ManagerApplicationsAcceptedUnsafe();
}

internal sealed record PlanReadyConfiguration(
    BootstrapConfiguration Configuration,
    string SerializedJson,
    PlanReadinessToken Readiness);

internal sealed record PlanReadinessToken(
    string ConfigurationFingerprint);
