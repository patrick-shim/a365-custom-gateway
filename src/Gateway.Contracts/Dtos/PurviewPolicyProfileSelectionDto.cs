namespace Gateway.Contracts.Dtos;

/// <summary>
/// Selects how a newly-created Agent Identity blueprint is attached to a
/// Gateway-managed Purview protection profile. This contract contains names
/// and identifiers only; tenant credentials never cross the API boundary.
/// </summary>
public sealed record PurviewPolicyProfileSelectionDto(
    string Mode,
    Guid? ProfileId,
    string? DisplayName,
    string? Template);
