using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed class SetupWizardState
{
    private readonly object sync = new();
    private IReadOnlyList<AzureSubscription> subscriptions = [];

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
        }
        else
        {
            selected = discovered.FirstOrDefault(subscription => subscription.IsDefault) ?? discovered.FirstOrDefault();
        }

        if (selected is not null)
        {
            Form.SelectSubscription(selected);
            AccountSelectionIssue = null;
        }
    }

    public bool SelectSubscription(Guid subscriptionId)
    {
        var subscription = Subscriptions.FirstOrDefault(item => item.SubscriptionId == subscriptionId);
        if (subscription is null)
        {
            return false;
        }

        Form.SelectSubscription(subscription);
        AccountSelectionIssue = null;
        return true;
    }

    public void MarkConfigurationWritten(string path)
    {
        ConfigurationWritten = true;
        ConfigurationPath = path;
    }
}
