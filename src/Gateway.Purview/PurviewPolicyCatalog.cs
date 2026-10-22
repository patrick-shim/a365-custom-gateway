using Gateway.Domain.Models;

namespace Gateway.Purview;

public sealed record PurviewExistingPolicy(Guid Id, string DisplayName, string Mode,
    string[] EnforcementPlanes, Guid[] IndividualApplicationIds, bool HasUploadTextBlock,
    string Revision, Guid[]? AllAccountsApplicationIds = null);
public sealed record PurviewPolicyCatalog(Guid TenantId, DateTimeOffset RetrievedAtUtc,
    IReadOnlyList<PurviewExistingPolicy> Items);

public interface IPurviewPolicyCatalogClient
{
    Task<PurviewPolicyCatalog> ReadAsync(Guid tenantId, CancellationToken cancellationToken);
}

public static class PurviewPolicyCatalogValidation
{
    // This threshold is used for live management review, not for displaying an
    // already authenticated inventory or for runtime protection admission.
    public static readonly TimeSpan MaximumAge = TimeSpan.FromDays(30);

    // A result produced for a live connector command must still be recent. This
    // is deliberately independent of how long an accepted snapshot may be reused.
    public static readonly TimeSpan MaximumConnectorResultAge = TimeSpan.FromMinutes(15);

    public static void Validate(PurviewPolicyCatalog catalog, Guid tenantId)
    {
        if (tenantId == Guid.Empty || catalog is null || catalog.TenantId != tenantId || catalog.Items is null ||
            catalog.Items.Count > 2048 || catalog.RetrievedAtUtc > DateTimeOffset.UtcNow.AddMinutes(1) ||
            catalog.Items.Any(x => x is null) ||
            catalog.Items.Select(x => x.Id).Distinct().Count() != catalog.Items.Count ||
            catalog.Items.Any(x => x.Id == Guid.Empty || string.IsNullOrWhiteSpace(x.DisplayName) ||
                x.DisplayName.Length > 256 || x.DisplayName.Any(char.IsControl) || string.IsNullOrWhiteSpace(x.Mode) ||
                x.EnforcementPlanes is null || x.IndividualApplicationIds is null ||
                x.IndividualApplicationIds.Any(id => id == Guid.Empty) ||
                (x.AllAccountsApplicationIds is not null && (x.AllAccountsApplicationIds.Any(id => id == Guid.Empty || !x.IndividualApplicationIds.Contains(id)) ||
                    x.AllAccountsApplicationIds.Distinct().Count() != x.AllAccountsApplicationIds.Length)) ||
                x.Revision is not { Length: 64 } || !x.Revision.All(char.IsAsciiHexDigitLower)))
            throw new PurviewPolicyException("PURVIEW_POLICY_CATALOG_INVALID", "Purview returned an invalid policy catalog.");
    }

    public static void EnsureFreshForManagement(PurviewPolicyCatalog catalog)
    {
        if (catalog.RetrievedAtUtc < DateTimeOffset.UtcNow.Subtract(MaximumAge))
            throw new PurviewPolicyException("PURVIEW_POLICY_CATALOG_REFRESH_REQUIRED",
                "Refresh the Purview policy catalog before reviewing or confirming a policy change.");
    }

    public static string? Incompatibility(PurviewExistingPolicy policy) =>
        policy.Mode != "Enable" ? "The policy is not in blocking mode. Ask its owner to review it in Purview." :
        !policy.EnforcementPlanes.Contains("Application", StringComparer.Ordinal) ? "The policy does not support Entra application locations." :
        !policy.HasUploadTextBlock ? "The policy has no enabled upload-text blocking rule." : null;
}

