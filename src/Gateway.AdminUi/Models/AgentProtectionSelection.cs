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

    internal AgentProtectionSelection WithSensitiveInformationType(string id, bool selected)
    {
        var thresholds = new Dictionary<string, AgentProtectionSitThresholds>(
            SensitiveInformationTypeThresholds, StringComparer.OrdinalIgnoreCase);
        if (!thresholds.ContainsKey(id))
        {
            // Retain an unknown legacy selection even after removal; reselecting it is not a new type.
            thresholds[id] = selected && !SensitiveInformationTypeIds.Contains(id, StringComparer.OrdinalIgnoreCase)
                ? AgentProtectionSitThresholds.StartingValues
                : new();
        }
        return this with
        {
            SensitiveInformationTypeIds = selected
                ? SensitiveInformationTypeIds.Append(id).Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
                : SensitiveInformationTypeIds.Where(existing => !string.Equals(existing, id, StringComparison.OrdinalIgnoreCase)).ToArray(),
            SensitiveInformationTypeThresholds = thresholds
        };
    }

    internal bool HasSamePolicyChoices(AgentProtectionSelection other) =>
        BlueprintId == other.BlueprintId &&
        PurviewEnabled == other.PurviewEnabled &&
        PolicyMode == other.PolicyMode &&
        SensitiveInformationTypeIds.Count == other.SensitiveInformationTypeIds.Count &&
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
        else if (!deferredBlueprint && blueprints.Items.Count(item => item.Id == BlueprintId) != 1)
        {
            errors.Add("The selected blueprint is missing or duplicated in the inventory. Select one exact available blueprint.");
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
        else if (SensitiveInformationTypeIds.Count > 100 ||
                 SensitiveInformationTypeIds.Distinct(StringComparer.OrdinalIgnoreCase).Count() != SensitiveInformationTypeIds.Count)
        {
            errors.Add("Select 1-100 distinct sensitive information types.");
        }
        else if (sensitiveInformationTypes.CurrentState == ProtectionInventoryState.Ready &&
                 SensitiveInformationTypeIds.Any(id => sensitiveInformationTypes.Items.Count(
                     item => string.Equals(item.Id, id, StringComparison.OrdinalIgnoreCase)) != 1))
        {
            errors.Add("Remove or replace selected sensitive information type IDs that are missing or duplicated in the inventory.");
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
    int? MaxConfidence = null)
{
    internal static AgentProtectionSitThresholds StartingValues => new(1, -1, 75, 100);
}

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
    public TimeProvider Clock { get; init; } = TimeProvider.System;

    public ProtectionInventoryState CurrentState =>
        State == ProtectionInventoryState.Ready && ExpiresAtUtc <= Clock.GetUtcNow()
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
