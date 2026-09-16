namespace Gateway.AdminUi.Models;

// UI drafts only: these types are not API contracts or evidence of persisted protection.
public sealed record AgentProtectionSelection
{
    public Guid? BlueprintId { get; init; }
    public bool PromptShieldsEnabled { get; init; }
    public bool PurviewEnabled { get; init; }
    public IReadOnlyList<string> SensitiveInformationTypeIds { get; init; } = [];
    public IReadOnlyDictionary<string, AgentProtectionSitThresholds> SensitiveInformationTypeThresholds { get; init; } =
        new Dictionary<string, AgentProtectionSitThresholds>();
    public string SensitiveInformationTypeMatchOperator => "Or";
    public PurviewPolicyMode? PolicyMode { get; init; }
    public string? ProviderPolicyMode => PolicyMode switch
    {
        PurviewPolicyMode.Enforce => "Enable",
        PurviewPolicyMode.SimulationWithPolicyTips => "TestWithNotifications",
        PurviewPolicyMode.SilentSimulation => "TestWithoutNotifications",
        PurviewPolicyMode.CreateButLeaveOff => "Disable",
        _ => null
    };

    internal AgentProtectionSelection Snapshot() => this with
    {
        SensitiveInformationTypeIds = Array.AsReadOnly(SensitiveInformationTypeIds.ToArray()),
        SensitiveInformationTypeThresholds =
            new System.Collections.ObjectModel.ReadOnlyDictionary<string, AgentProtectionSitThresholds>(
                SensitiveInformationTypeThresholds.ToDictionary(item => item.Key, item => item.Value))
    };

    internal AgentProtectionSitThresholds? ThresholdsFor(string id) =>
        SensitiveInformationTypeThresholds.FirstOrDefault(item =>
            string.Equals(item.Key, id, StringComparison.OrdinalIgnoreCase)).Value;

    internal bool HasSamePolicyChoices(AgentProtectionSelection other) =>
        BlueprintId == other.BlueprintId &&
        PurviewEnabled == other.PurviewEnabled &&
        PolicyMode == other.PolicyMode &&
        SensitiveInformationTypeIds.ToHashSet(StringComparer.OrdinalIgnoreCase)
            .SetEquals(other.SensitiveInformationTypeIds) &&
        SensitiveInformationTypeIds.All(id => ThresholdsFor(id) == other.ThresholdsFor(id));

    internal bool HasSameChoices(AgentProtectionSelection other) =>
        PromptShieldsEnabled == other.PromptShieldsEnabled && HasSamePolicyChoices(other) &&
        SensitiveInformationTypeThresholds.Count == other.SensitiveInformationTypeThresholds.Count &&
        SensitiveInformationTypeThresholds.All(item => item.Value == other.ThresholdsFor(item.Key));

    internal IReadOnlyList<string> Validate(
        ProtectionInventory<AgentProtectionBlueprint> blueprints,
        ProtectionInventory<AgentProtectionSensitiveInformationType> sensitiveInformationTypes,
        bool deferredBlueprint = false)
    {
        var errors = new List<string>();
        if (!deferredBlueprint && blueprints.CurrentState != ProtectionInventoryState.Ready)
        {
            errors.Add("Refresh the blueprint inventory before continuing.");
        }
        else if (!deferredBlueprint && (BlueprintId is null || BlueprintId == Guid.Empty))
        {
            errors.Add("Select a blueprint before configuring protection.");
        }
        else if (!deferredBlueprint && !blueprints.Items.Any(item => item.Id == BlueprintId))
        {
            errors.Add("The selected blueprint is no longer in the inventory. Select an available blueprint.");
        }

        if (!PurviewEnabled)
        {
            return errors;
        }

        if (sensitiveInformationTypes.CurrentState != ProtectionInventoryState.Ready)
        {
            errors.Add("Refresh the sensitive information type inventory before enabling Purview.");
        }

        if (SensitiveInformationTypeIds.Count == 0 || SensitiveInformationTypeIds.Any(string.IsNullOrWhiteSpace))
        {
            errors.Add("Select at least one sensitive information type for Purview.");
        }
        else if (sensitiveInformationTypes.CurrentState == ProtectionInventoryState.Ready &&
                 SensitiveInformationTypeIds.Any(id => !sensitiveInformationTypes.Items.Any(
                     item => string.Equals(item.Id, id, StringComparison.OrdinalIgnoreCase))))
        {
            errors.Add("Remove or replace selected sensitive information type IDs that are no longer available.");
        }

        if (PolicyMode is null || !Enum.IsDefined(PolicyMode.Value))
        {
            errors.Add("Choose a Purview policy mode.");
        }

        return errors;
    }
}

// Existing per-SIT values are retained, including while a SIT is deselected. Null means unspecified,
// not a new default. The host maps selected IDs and their individual thresholds to its reviewed DTO.
public sealed record AgentProtectionSitThresholds(
    int? MinCount = null,
    int? MaxCount = null,
    int? MinConfidence = null,
    int? MaxConfidence = null);

// Policy lifecycle modes deliberately do not reuse the Gateway's AuditOnly/Enforce runtime gate.
public enum PurviewPolicyMode
{
    Enforce,
    SimulationWithPolicyTips,
    SilentSimulation,
    CreateButLeaveOff
}

public enum ProtectionInventoryState
{
    NotLoaded,
    Loading,
    Ready,
    Unavailable,
    Stale
}

public sealed record ProtectionInventory<T>
{
    public ProtectionInventoryState State { get; init; } = ProtectionInventoryState.NotLoaded;
    public IReadOnlyList<T> Items { get; init; } = [];
    public DateTimeOffset? ExpiresAtUtc { get; init; }

    public ProtectionInventoryState CurrentState =>
        State == ProtectionInventoryState.Ready && ExpiresAtUtc <= DateTimeOffset.UtcNow
            ? ProtectionInventoryState.Stale
            : State;
}

public sealed record AgentProtectionBlueprint(Guid Id, string DisplayName);

public sealed record AgentProtectionSensitiveInformationType(
    string Id,
    string DisplayName,
    string? Description = null);

public enum AgentProtectionReadinessState
{
    Unverified,
    Ready,
    Pending,
    Unavailable,
    Error,
    ConfiguredSimulation,
    ConfiguredOff
}

public sealed record AgentProtectionReadinessSignal(
    AgentProtectionReadinessState State,
    string? EffectiveSummary = null,
    string? Detail = null);

public sealed record AgentProtectionReadiness(
    AgentProtectionSelection AssessedSelection,
    AgentProtectionReadinessSignal PromptShields,
    AgentProtectionReadinessSignal Purview)
{
    // Capture evidence once, not during rerenders after the host may have mutated its draft.
    private readonly AgentProtectionSelection assessedSelection = AssessedSelection.Snapshot();

    public AgentProtectionSelection AssessedSelection
    {
        get => assessedSelection;
        init => assessedSelection = value.Snapshot();
    }
}

public sealed record AgentProtectionReview(
    AgentProtectionSelection Selection,
    bool SharedPolicyImpactAcknowledged,
    string? SharedPolicyReviewKey);
