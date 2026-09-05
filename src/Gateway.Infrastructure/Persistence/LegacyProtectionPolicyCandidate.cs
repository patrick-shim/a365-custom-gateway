namespace Gateway.Infrastructure.Persistence;

/// <summary>
/// Retained migration evidence from a legacy combined Purview profile. These
/// rows have no tenant binding and are never used as active policy state.
/// A reviewed API operation creates the real tenant-bound aggregate instead.
/// </summary>
internal sealed class LegacyProtectionPolicyCandidate
{
    public Guid Id { get; set; }
    public Guid LegacySourceProfileId { get; set; }
    public string CandidateKind { get; set; } = string.Empty;
    public string BindingStatus { get; set; } = "Unbound";
    public string ReviewStatus { get; set; } = "ReviewRequired";
    public Guid? BlueprintApplicationId { get; set; }
    public string ScopeType { get; set; } = string.Empty;
    public Guid LocationId { get; set; }
    public string EnforcementPlane { get; set; } = "Application";
    public string DisplayName { get; set; } = string.Empty;
    public string LegacyTemplate { get; set; } = string.Empty;
    public string Mode { get; set; } = string.Empty;
    public string LegacyStatus { get; set; } = string.Empty;
    public string? CollectionPolicyProviderId { get; set; }
    public string? DlpPolicyProviderId { get; set; }
    public string? DlpRuleProviderId { get; set; }
    public DateTime? LegacyVerifiedAtUtc { get; set; }
    public string? LegacyFailureCode { get; set; }
    public string CreatedByObjectId { get; set; } = string.Empty;
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];
}
