using Gateway.Domain.Models;

namespace Gateway.Purview;

public sealed class PurviewTenantConnectionEvidenceValidator
{
    public const int MaximumSensitiveInformationTypes = 2048;
    public const int MaximumSensitiveInformationTypeNameLength = 255;
    public const int MaximumPublisherLength = 200;
    public const int MaximumEvidenceMinutes = 15;

    public static IReadOnlyList<string> RequiredCapabilities { get; } =
        Array.AsReadOnly(new[]
        {
            "DlpPolicy.ReadWrite",
            "DlpRule.ReadWrite",
            "KnowYourData.ReadWrite",
            "SensitiveInformationTypes.Read"
        });

    public ValidatedPurviewTenantConnectionEvidence Validate(
        PurviewTenantConnectionOperationBinding binding,
        PurviewTenantConnectionCompanionEvidence evidence,
        DateTimeOffset utcNow)
    {
        ArgumentNullException.ThrowIfNull(binding);
        ArgumentNullException.ThrowIfNull(evidence);
        if (utcNow.Offset != TimeSpan.Zero)
            throw Failure(
                "PURVIEW_CONNECTION_EVIDENCE_INVALID",
                "Purview connection evidence validation requires a UTC clock.");

        ValidateBinding(binding);
        var operationId = ParseCanonicalId(evidence.OperationId);
        var tenantId = ParseCanonicalId(evidence.TenantId);
        var administratorObjectId = ParseCanonicalId(evidence.AdministratorObjectId);
        var generationId = ParseCanonicalId(evidence.InventoryGenerationId);
        if (operationId != binding.OperationId ||
            tenantId != binding.TenantId ||
            administratorObjectId != binding.AdministratorObjectId ||
            generationId != binding.InventoryGenerationId ||
            evidence.InventoryExpiresAtUtc != binding.ExpiresAtUtc)
        {
            throw Failure(
                "PURVIEW_CONNECTION_BINDING_MISMATCH",
                "Purview connection evidence does not match the exact pending operation.");
        }

        if (evidence.ObservedAtUtc.Offset != TimeSpan.Zero ||
            evidence.InventoryExpiresAtUtc.Offset != TimeSpan.Zero ||
            evidence.ObservedAtUtc > utcNow.AddMinutes(2) ||
            evidence.InventoryExpiresAtUtc <= utcNow ||
            evidence.InventoryExpiresAtUtc <= evidence.ObservedAtUtc ||
            evidence.InventoryExpiresAtUtc >
                evidence.ObservedAtUtc.AddMinutes(MaximumEvidenceMinutes))
        {
            throw Failure(
                "PURVIEW_CONNECTION_EVIDENCE_EXPIRED",
                "Purview connection evidence is expired or outside its bounded lifetime.");
        }

        ValidateCapabilities(evidence.AuthorizedCapabilities);
        var inventory = ProjectInventory(
            generationId,
            tenantId,
            evidence.ObservedAtUtc,
            evidence.InventoryExpiresAtUtc,
            evidence.SensitiveInformationTypes);
        return new ValidatedPurviewTenantConnectionEvidence(
            operationId,
            tenantId,
            administratorObjectId,
            evidence.ObservedAtUtc,
            evidence.InventoryExpiresAtUtc,
            RequiredCapabilities,
            inventory);
    }

    public PurviewTenantSensitiveInformationTypeInventory ProjectInventory(
        Guid generationId,
        Guid tenantId,
        DateTimeOffset retrievedAtUtc,
        DateTimeOffset expiresAtUtc,
        IReadOnlyList<PurviewSensitiveInformationTypeEvidence> items)
    {
        if (items is null)
            throw InventoryFailure();
        if (generationId == Guid.Empty ||
            tenantId == Guid.Empty ||
            retrievedAtUtc.Offset != TimeSpan.Zero ||
            expiresAtUtc.Offset != TimeSpan.Zero ||
            expiresAtUtc <= retrievedAtUtc ||
            items.Count is < 1 or > MaximumSensitiveInformationTypes)
        {
            throw Failure(
                "PURVIEW_SIT_INVENTORY_INVALID",
                "Purview sensitive-information-type inventory is invalid or outside its bounds.");
        }

        var identifiers = new HashSet<Guid>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        var projected = new List<PurviewSensitiveInformationTypeProjection>(items.Count);
        foreach (var item in items)
        {
            if (item is null)
                throw InventoryFailure();

            var id = ParseCanonicalId(item.Id, inventory: true);
            if (!identifiers.Add(id) ||
                !IsBoundedText(item.ExactName, MaximumSensitiveInformationTypeNameLength) ||
                !names.Add(item.ExactName) ||
                !IsBoundedText(item.Publisher, MaximumPublisherLength))
            {
                throw InventoryFailure();
            }

            projected.Add(new PurviewSensitiveInformationTypeProjection(
                id,
                item.ExactName,
                item.Publisher,
                0));
        }

        var ordered = projected
            .OrderBy(item => item.ExactName, StringComparer.Ordinal)
            .ThenBy(item => item.Id)
            .Select((item, index) => item with { SortOrder = index })
            .ToArray();
        return new PurviewTenantSensitiveInformationTypeInventory(
            generationId,
            tenantId,
            retrievedAtUtc,
            expiresAtUtc,
            ordered);
    }

    private static void ValidateBinding(PurviewTenantConnectionOperationBinding binding)
    {
        if (binding.OperationId == Guid.Empty ||
            binding.TenantId == Guid.Empty ||
            binding.AdministratorObjectId == Guid.Empty ||
            binding.InventoryGenerationId == Guid.Empty ||
            binding.ExpiresAtUtc.Offset != TimeSpan.Zero)
        {
            throw Failure(
                "PURVIEW_CONNECTION_BINDING_INVALID",
                "The pending Purview connection operation binding is invalid.");
        }
    }

    private static void ValidateCapabilities(IReadOnlyList<string> capabilities)
    {
        if (capabilities is null ||
            capabilities.Count != RequiredCapabilities.Count ||
            capabilities.Any(capability =>
                !IsBoundedText(capability, 64)) ||
            capabilities.Distinct(StringComparer.Ordinal).Count() != capabilities.Count ||
            !capabilities.OrderBy(value => value, StringComparer.Ordinal).SequenceEqual(
                RequiredCapabilities,
                StringComparer.Ordinal))
        {
            throw Failure(
                "PURVIEW_CONNECTION_AUTHORIZATION_INVALID",
                "Purview companion authorization evidence is incomplete or unsupported.");
        }
    }

    private static Guid ParseCanonicalId(string value, bool inventory = false)
    {
        if (!Guid.TryParse(value, out var parsed) ||
            parsed == Guid.Empty ||
            !string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal))
        {
            throw inventory
                ? InventoryFailure()
                : Failure(
                    "PURVIEW_CONNECTION_EVIDENCE_INVALID",
                    "Purview connection evidence contains a noncanonical identifier.");
        }

        return parsed;
    }

    internal static bool IsBoundedText(string? value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximumLength)
            return false;

        return value.All(character => character > '\u001f' && character != '\u007f');
    }

    private static PurviewPolicyException InventoryFailure() =>
        Failure(
            "PURVIEW_SIT_INVENTORY_INVALID",
            "Purview sensitive-information-type inventory contains invalid or duplicate entries.");

    private static PurviewPolicyException Failure(string code, string message) =>
        new(code, message);
}
