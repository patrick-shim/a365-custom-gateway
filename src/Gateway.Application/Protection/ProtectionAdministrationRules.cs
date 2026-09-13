using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Application.Protection;

internal static class ProtectionAdministrationRules
{
    internal const string ReadinessDisclaimer =
        "Exact policy readback is not propagation, token-role, or runtime-verdict proof.";
    internal const string DlpThresholdDisclaimer =
        "The rule matches ANY selected SIT (OR), with each SIT's reviewed count and confidence thresholds. " +
        "New-policy omitted thresholds use the Microsoft example values 1 / Any (-1) / 75 / 100; " +
        "these are reviewable starting values, not universally safe recommendations.";

    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 12,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static async Task RequirePurviewCapabilityAsync(
        IProtectionCapabilityRepository capabilities,
        CancellationToken cancellationToken)
    {
        var capability = await capabilities.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            cancellationToken);
        if (capability is null ||
            capability.Status != ProtectionCapabilityStatus.Installed ||
            capability.LastReadbackAtUtc is null)
        {
            throw new DomainException(
                "Microsoft Purview prerequisites do not have an exact installed capability readback.",
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        }
    }

    public static async Task<PurviewTenantConnection> RequireConnectionAsync(
        IPurviewTenantConnectionRepository connections,
        ProtectionActor actor,
        Guid connectionId,
        DateTime utcNow,
        bool mustBeUsable,
        CancellationToken cancellationToken)
    {
        var connection = await connections.GetByIdAsync(connectionId, cancellationToken);
        if (connection is null || connection.TenantId.Value != actor.TenantId)
        {
            throw new DomainException(
                "The Purview tenant connection is unavailable for this tenant.",
                ErrorCodes.PURVIEW_TENANT_NOT_CONNECTED);
        }

        if (mustBeUsable && !connection.IsUsableAt(utcNow))
        {
            throw new DomainException(
                "The Purview tenant connection is not currently verified and usable.",
                ErrorCodes.PURVIEW_TENANT_NOT_CONNECTED);
        }

        return connection;
    }

    public static async Task<ValidatedSensitiveInformationType> RequireInventorySelectionAsync(
        IPurviewSensitiveInformationTypeSnapshotRepository inventory,
        PurviewTenantConnection connection,
        PurviewSensitiveInformationTypeSelectionDto selection,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(selection);
        if (selection.InventoryGenerationId == Guid.Empty ||
            selection.SensitiveInformationTypeId == Guid.Empty ||
            !IsBoundedText(selection.ExactName, 255))
        {
            throw InventoryStale();
        }

        var generationId = new SensitiveInformationTypeSnapshotGenerationId(
            selection.InventoryGenerationId);
        var generation = await inventory.GetGenerationAsync(
            generationId,
            cancellationToken);
        if (generation is null ||
            generation.TenantId != connection.TenantId ||
            connection.ActiveInventoryGenerationId != generationId ||
            generation.IsExpired(utcNow))
        {
            throw InventoryStale();
        }

        var matches = generation.Items
            .Where(item =>
                item.SensitiveInformationTypeId.Value ==
                selection.SensitiveInformationTypeId)
            .ToArray();
        if (matches.Length != 1 ||
            !string.Equals(
                matches[0].ExactName,
                selection.ExactName,
                StringComparison.Ordinal))
        {
            throw InventoryStale();
        }

        return new ValidatedSensitiveInformationType(
            generation,
            matches[0]);
    }

    public static PurviewMode ParseMode(string value)
    {
        if (!Enum.TryParse<PurviewMode>(
                value,
                ignoreCase: false,
                out var mode) ||
            !Enum.IsDefined(mode) || !string.Equals(mode.ToString(), value, StringComparison.Ordinal))
        {
            throw Validation(
                "Mode",
                "Mode must be the exact supported AuditOnly or Enforce value.");
        }

        return mode;
    }

    public static PurviewPolicyMode ParsePolicyMode(string? value, string legacyMode)
    {
        var legacy = ParseMode(legacyMode);
        if (value is null)
            return PurviewPolicyModeCompatibility.FromLegacy(legacy);
        if (!Enum.TryParse<PurviewPolicyMode>(value, false, out var mode) ||
            !Enum.IsDefined(mode) || !string.Equals(mode.ToString(), value, StringComparison.Ordinal) || mode.ToLegacy() != legacy)
            throw Validation("PolicyMode", "Select an exact supported policy mode and compatible legacy Mode.");
        return mode;
    }

    public static IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> NormalizeSelections(
        PurviewSensitiveInformationTypeSelectionDto? legacy,
        IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto>? selections)
    {
        var values = selections ?? (legacy is null ? [] : [legacy]);
        if (values.Count is < 1 or > 100 ||
            values.Any(value => value is null) ||
            values.Select(value => value.SensitiveInformationTypeId).Distinct().Count() != values.Count ||
            values.Select(value => value.InventoryGenerationId).Distinct().Count() != 1 ||
            (legacy is not null && !values.Any(value =>
                value.InventoryGenerationId == legacy.InventoryGenerationId &&
                value.SensitiveInformationTypeId == legacy.SensitiveInformationTypeId &&
                value.ExactName == legacy.ExactName &&
                (legacy.MinCount is null || value.MinCount == legacy.MinCount) &&
                (legacy.MaxCount is null || value.MaxCount == legacy.MaxCount) &&
                (legacy.MinConfidence is null || value.MinConfidence == legacy.MinConfidence) &&
                (legacy.MaxConfidence is null || value.MaxConfidence == legacy.MaxConfidence))))
            throw Validation("SensitiveInformationTypes", "Select 1–100 distinct real SITs from one current inventory generation.");
        return values.OrderBy(value => value.SensitiveInformationTypeId).ToArray();
    }

    internal static IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> DlpSelections(PurviewDlpProfileReviewPayload payload)
    {
        var selections = NormalizeSelections(new(payload.InventoryGenerationId, payload.SensitiveInformationTypeId,
            payload.SensitiveInformationTypeName), payload.SensitiveInformationTypes);
        if (selections.Any(value => value.MinCount is null || value.MaxCount is null ||
                                   value.MinConfidence is null || value.MaxConfidence is null))
            throw ThresholdReviewRequired();
        foreach (var value in selections)
            ValidateThresholds(value);
        return selections;
    }

    internal static IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> NormalizeDlpThresholds(
        IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> selections,
        PurviewDlpProfile? existing)
    {
        // A full, explicitly reviewed replacement is supported; an omission is never consent to invent legacy thresholds.
        if (HasUnverifiedLegacyThresholds(existing) && selections.Any(value =>
                value.MinCount is null || value.MaxCount is null ||
                value.MinConfidence is null || value.MaxConfidence is null))
            throw ThresholdReviewRequired();

        return NormalizeSelections(null, selections).Select(value =>
        {
            var previous = existing?.NormalizedSensitiveInformationTypes.SingleOrDefault(type =>
                type.Id == value.SensitiveInformationTypeId && type.ExactName == value.ExactName);
            var omitted = value.MinCount is null || value.MaxCount is null ||
                          value.MinConfidence is null || value.MaxConfidence is null;
            if (existing is not null && omitted &&
                (previous is null || existing.LastReadbackAtUtc is null ||
                 existing.Readiness.Readback != ProtectionReadbackStatus.Ready ||
                 string.IsNullOrWhiteSpace(existing.DlpPolicyProviderId) ||
                 string.IsNullOrWhiteSpace(existing.DlpRuleProviderId) ||
                 !PurviewSensitiveInformationTypeThresholds.AreValid(previous.MinCount, previous.MaxCount,
                     previous.MinConfidence, previous.MaxConfidence)))
                throw ThresholdReviewRequired();
            var normalized = value with
            {
                MinCount = value.MinCount ?? previous?.MinCount ?? 1,
                MaxCount = value.MaxCount ?? previous?.MaxCount ?? -1,
                MinConfidence = value.MinConfidence ?? previous?.MinConfidence ?? 75,
                MaxConfidence = value.MaxConfidence ?? previous?.MaxConfidence ?? 100
            };
            ValidateThresholds(normalized);
            return normalized;
        }).ToArray();
    }

    internal static bool HasUnverifiedLegacyThresholds(PurviewDlpProfile? profile) =>
        profile is not null && profile.NormalizedSensitiveInformationTypes.Any(value =>
            !PurviewSensitiveInformationTypeThresholds.AreValid(
                value.MinCount, value.MaxCount, value.MinConfidence, value.MaxConfidence));

    internal static PurviewSelectedSensitiveInformationType ToSelectedType(PurviewSensitiveInformationTypeSelectionDto value) =>
        new(value.SensitiveInformationTypeId, value.ExactName,
            value.MinCount, value.MaxCount, value.MinConfidence, value.MaxConfidence);

    private static void ValidateThresholds(PurviewSensitiveInformationTypeSelectionDto value)
    {
        if (!PurviewSensitiveInformationTypeThresholds.AreValid(value.MinCount, value.MaxCount,
                value.MinConfidence, value.MaxConfidence))
            throw Validation("SensitiveInformationTypes",
                "Each SIT requires MinCount >= 1; MaxCount = -1 (Any) or >= MinCount; " +
                "and confidence bounds from 1 to 100 with MaxConfidence >= MinConfidence.");
    }

    private static DomainException ThresholdReviewRequired() =>
        new("Exact existing SIT count/confidence evidence is unavailable. Supply all four thresholds for every selected " +
            "SIT and review an explicit full replacement with shared-policy impact acknowledgment and the current row version. " +
            "Then reconcile the replacement. Inventory refresh alone cannot recover legacy rule thresholds; defaults will not be substituted.",
            ErrorCodes.PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED);

    public static async Task<IReadOnlyList<ValidatedSensitiveInformationType>> RequireInventorySelectionsAsync(
        IPurviewSensitiveInformationTypeSnapshotRepository inventory,
        PurviewTenantConnection connection,
        IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> selections,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        var result = new List<ValidatedSensitiveInformationType>();
        foreach (var selection in NormalizeSelections(null, selections))
            result.Add(await RequireInventorySelectionAsync(inventory, connection, selection, utcNow, cancellationToken));
        return result;
    }

    public static IReadOnlyList<PurviewPolicyActivity> ParseActivities(
        IReadOnlyList<string> values)
    {
        if (values is null || values.Count is < 1 or > 2)
        {
            throw Validation(
                "Activities",
                "Select between one and two supported Purview activities.");
        }

        var activities = new List<PurviewPolicyActivity>(values.Count);
        foreach (var value in values)
        {
            if (!Enum.TryParse<PurviewPolicyActivity>(
                    value,
                    ignoreCase: false,
                    out var activity) ||
                !Enum.IsDefined(activity) ||
                activities.Contains(activity))
            {
                throw Validation(
                    "Activities",
                    "Activities must be distinct exact supported values.");
            }

            activities.Add(activity);
        }

        return activities.OrderBy(value => value).ToArray();
    }

    public static IReadOnlyList<Domain.Models.PurviewDlpRuleAction> ParseActions(
        IReadOnlyList<PurviewDlpRuleActionDto> values,
        IReadOnlyList<PurviewPolicyActivity> activities)
    {
        if (values is not [{ Activity: "UploadText", Action: "Block" }] ||
            !activities.Contains(PurviewPolicyActivity.UploadText))
        {
            throw Validation(
                "Actions",
                "DLP profiles require the supported UploadText Block rule action. AuditOnly is selected through policy mode.");
        }
        return [new(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)];
    }

    public static void EnsureBoundedDisplayName(string displayName)
    {
        if (!IsBoundedText(displayName, 120))
        {
            throw Validation(
                "DisplayName",
                "DisplayName must contain between 1 and 120 safe characters.");
        }
    }

    public static void EnsureTenant(ProtectionActor actor, Guid tenantId)
    {
        if (tenantId == Guid.Empty || tenantId != actor.TenantId)
        {
            throw new ProtectionAccessDeniedException();
        }
    }

    public static void EnsureEvidence(
        PurviewTenantConnectionEvidenceDto evidence,
        ProtectionActor actor,
        DateTimeOffset utcNow)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        if (evidence.TenantId != actor.TenantId ||
            !Guid.TryParse(actor.ObjectId, out var actorObjectId) ||
            evidence.AdministratorObjectId != actorObjectId)
        {
            throw new ProtectionAccessDeniedException();
        }

        string[] requiredCapabilities =
        [
            "DlpPolicy.ReadWrite",
            "DlpRule.ReadWrite",
            "KnowYourData.ReadWrite",
            "SensitiveInformationTypes.Read"
        ];
        if (utcNow.Offset != TimeSpan.Zero ||
            evidence.ObservedAtUtc.Offset != TimeSpan.Zero ||
            evidence.InventoryExpiresAtUtc.Offset != TimeSpan.Zero ||
            evidence.ObservedAtUtc > utcNow.AddMinutes(2) ||
            evidence.InventoryExpiresAtUtc <= utcNow ||
            evidence.InventoryExpiresAtUtc <= evidence.ObservedAtUtc ||
            evidence.InventoryExpiresAtUtc > evidence.ObservedAtUtc.AddMinutes(15) ||
            evidence.AuthorizedCapabilities is null ||
            !evidence.AuthorizedCapabilities.SequenceEqual(requiredCapabilities) ||
            evidence.SensitiveInformationTypes is null ||
            evidence.SensitiveInformationTypes.Count is < 1 or > 2048)
        {
            throw Validation(
                "Evidence",
                "The bounded Purview companion evidence is invalid or expired.");
        }

        var identifiers = new HashSet<Guid>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in evidence.SensitiveInformationTypes)
        {
            if (item is null ||
                item.Id == Guid.Empty ||
                !identifiers.Add(item.Id) ||
                !IsBoundedText(item.ExactName, 255) ||
                !names.Add(item.ExactName) ||
                !IsBoundedText(item.Publisher, 200))
            {
                throw Validation(
                    "Evidence.SensitiveInformationTypes",
                    "The sensitive-information-type inventory is malformed or contains duplicates.");
            }
        }
    }

    public static T DeserializePayload<T>(JsonElement payload)
        where T : class =>
        payload.Deserialize<T>(JsonOptions)
        ?? throw new DomainException(
            "The reviewed protection operation payload is invalid.",
            ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

    internal static bool IsBoundedText(string? value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character => character > '\u001f' && character != '\u007f');

    internal static ValidationException Validation(string property, string message) =>
        new(new Dictionary<string, string[]>
        {
            [property] = [message]
        });

    private static DomainException InventoryStale() =>
        new(
            "The selected sensitive information type is absent, renamed, or from a stale inventory.",
            ErrorCodes.PURVIEW_INVENTORY_STALE);
}

internal sealed record ValidatedSensitiveInformationType(
    PurviewSensitiveInformationTypeSnapshotGeneration Generation,
    PurviewSensitiveInformationTypeSnapshot Item);
