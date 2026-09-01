using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed partial class SetupWizardState
{
    private IReadOnlyList<PurviewSensitiveInformationType> purviewSensitiveInformationTypes = [];
    private Guid purviewDiscoverySubscriptionId;
    private Guid purviewDiscoveryTenantId;
    private string? purviewDiscoveryGuidance;
    private string? purviewSelectionIssue;
    private string? purviewProvenance;

    public IReadOnlyList<PurviewSensitiveInformationType> PurviewSensitiveInformationTypes
    {
        get
        {
            lock (sync)
            {
                return purviewSensitiveInformationTypes;
            }
        }
    }

    public string? PurviewSensitiveInformationTypeDiscoveryGuidance
    {
        get
        {
            lock (sync)
            {
                return purviewDiscoveryGuidance;
            }
        }
    }

    public string? PurviewSensitiveInformationTypeSelectionIssue
    {
        get
        {
            lock (sync)
            {
                return purviewSelectionIssue;
            }
        }
    }

    public string? PurviewSensitiveInformationTypeProvenance
    {
        get
        {
            lock (sync)
            {
                return purviewProvenance;
            }
        }
    }

    public PurviewSensitiveInformationType? SelectedPurviewSensitiveInformationType
    {
        get
        {
            lock (sync)
            {
                return FindExactSelectedPurviewSensitiveInformationTypeUnsafe();
            }
        }
    }

    public bool HasCurrentPurviewSensitiveInformationTypeInventory
    {
        get
        {
            lock (sync)
            {
                return HasCurrentPurviewSensitiveInformationTypeInventoryUnsafe();
            }
        }
    }

    public bool HasValidPurviewSensitiveInformationTypeSelection
    {
        get
        {
            lock (sync)
            {
                return HasValidPurviewSensitiveInformationTypeSelectionUnsafe();
            }
        }
    }

    public bool SetPurviewEnabled(bool enabled)
    {
        lock (sync)
        {
            if (ExistingConfigurationLoaded && Form.PurviewEnabled != enabled)
            {
                return false;
            }

            if (Form.PurviewEnabled == enabled)
            {
                return true;
            }

            Form.PurviewEnabled = enabled;
            ResetPurviewSensitiveInformationTypeDiscoveryUnsafe(
                clearForm: !ExistingConfigurationLoaded);
            return true;
        }
    }

    public void BeginPurviewSensitiveInformationTypeDiscovery()
    {
        lock (sync)
        {
            ResetPurviewSensitiveInformationTypeDiscoveryUnsafe(clearForm: false);
        }
    }

    public void ApplyPurviewSensitiveInformationTypeDiscovery(
        PurviewSensitiveInformationTypeDiscoveryResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        lock (sync)
        {
            purviewSensitiveInformationTypes = [];
            purviewDiscoverySubscriptionId = result.SubscriptionId;
            purviewDiscoveryTenantId = result.TenantId;
            purviewDiscoveryGuidance = result.Guidance;
            purviewSelectionIssue = null;
            purviewProvenance = null;

            if (!Form.PurviewEnabled ||
                result.SubscriptionId != Form.SubscriptionId ||
                result.TenantId != Form.TenantId ||
                !HasEnabledSelectedSubscriptionUnsafe())
            {
                purviewDiscoverySubscriptionId = Guid.Empty;
                purviewDiscoveryTenantId = Guid.Empty;
                purviewDiscoveryGuidance =
                    "The selected subscription or tenant changed while Purview types were loading. Reload the exact current tenant inventory.";
                if (!ExistingConfigurationLoaded)
                {
                    Form.ClearPurviewSensitiveInformationType();
                }

                return;
            }

            if (!result.Succeeded || !IsValidPurviewInventory(result.Types))
            {
                purviewDiscoveryGuidance ??=
                    "Purview returned an unexpected or ambiguous tenant inventory. Setup accepted no sensitive information type.";
                if (!ExistingConfigurationLoaded)
                {
                    Form.ClearPurviewSensitiveInformationType();
                }

                return;
            }

            purviewSensitiveInformationTypes = result.Types
                .OrderBy(type => type.Name, StringComparer.Ordinal)
                .ThenBy(type => type.Id.ToString("D"), StringComparer.Ordinal)
                .ToArray();
            purviewProvenance = PurviewSensitiveInformationTypeDiscovery.Provenance;
            if (FindExactSelectedPurviewSensitiveInformationTypeUnsafe() is not null)
            {
                return;
            }

            if (ExistingConfigurationLoaded &&
                (Form.PurviewSensitiveInformationTypeId != Guid.Empty ||
                 !string.IsNullOrEmpty(Form.PurviewSensitiveInformationType)))
            {
                purviewSelectionIssue =
                    "The imported Purview sensitive information type GUID and exact name are not both present in the current tenant inventory. Setup will not substitute or rename it.";
                return;
            }

            Form.ClearPurviewSensitiveInformationType();
        }
    }

    public bool SelectPurviewSensitiveInformationType(Guid typeId)
    {
        if (ExistingConfigurationLoaded)
        {
            return false;
        }

        lock (sync)
        {
            if (!Form.PurviewEnabled ||
                !HasCurrentPurviewSensitiveInformationTypeInventoryUnsafe())
            {
                return false;
            }

            var selected = purviewSensitiveInformationTypes.SingleOrDefault(type =>
                type.Id == typeId);
            if (selected is null)
            {
                return false;
            }

            Form.PurviewSensitiveInformationTypeId = selected.Id;
            Form.PurviewSensitiveInformationType = selected.Name;
            purviewSelectionIssue = null;
            return true;
        }
    }

    private void ResetPurviewSensitiveInformationTypeDiscovery(bool clearForm)
    {
        lock (sync)
        {
            ResetPurviewSensitiveInformationTypeDiscoveryUnsafe(clearForm);
        }
    }

    private void ResetPurviewSensitiveInformationTypeDiscoveryUnsafe(bool clearForm)
    {
        purviewSensitiveInformationTypes = [];
        purviewDiscoverySubscriptionId = Guid.Empty;
        purviewDiscoveryTenantId = Guid.Empty;
        purviewDiscoveryGuidance = null;
        purviewSelectionIssue = null;
        purviewProvenance = null;
        if (clearForm)
        {
            Form.ClearPurviewSensitiveInformationType();
        }
    }

    private bool HasCurrentPurviewSensitiveInformationTypeInventoryUnsafe() =>
        Form.PurviewEnabled &&
        HasEnabledSelectedSubscriptionUnsafe() &&
        purviewDiscoveryGuidance is null &&
        purviewSensitiveInformationTypes.Count is > 0 and <= 2048 &&
        purviewDiscoverySubscriptionId == Form.SubscriptionId &&
        purviewDiscoveryTenantId == Form.TenantId;

    private bool HasValidPurviewSensitiveInformationTypeSelectionUnsafe() =>
        HasCurrentPurviewSensitiveInformationTypeInventoryUnsafe() &&
        purviewSelectionIssue is null &&
        FindExactSelectedPurviewSensitiveInformationTypeUnsafe() is not null;

    private PurviewSensitiveInformationType? FindExactSelectedPurviewSensitiveInformationTypeUnsafe() =>
        purviewSensitiveInformationTypes.SingleOrDefault(type =>
            type.Id == Form.PurviewSensitiveInformationTypeId &&
            string.Equals(
                type.Name,
                Form.PurviewSensitiveInformationType,
                StringComparison.Ordinal));

    private static bool IsValidPurviewInventory(
        IReadOnlyList<PurviewSensitiveInformationType> inventory) =>
        inventory.Count is > 0 and <= 2048 &&
        inventory.All(type =>
            type.Id != Guid.Empty &&
            IsExactProviderString(type.Name, 255, allowEmpty: false) &&
            IsExactProviderString(type.Publisher, 200, allowEmpty: true)) &&
        inventory.Select(type => type.Id).Distinct().Count() == inventory.Count &&
        inventory.Select(type => type.Name).Distinct(StringComparer.Ordinal).Count() == inventory.Count;

    private static bool IsExactProviderString(
        string? value,
        int maximumLength,
        bool allowEmpty) =>
        value is not null &&
        (allowEmpty || value.Length > 0) &&
        value.Length <= maximumLength &&
        string.Equals(value, value.Trim(), StringComparison.Ordinal) &&
        !value.Any(char.IsControl);
}
