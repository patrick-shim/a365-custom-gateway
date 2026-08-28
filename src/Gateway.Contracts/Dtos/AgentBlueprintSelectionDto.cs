namespace Gateway.Contracts.Dtos;

/// <summary>
/// Selects the reusable Agent Identity blueprint. Gateway runtime credentials
/// are trusted service configuration and never belong in this client contract.
/// </summary>
public sealed record AgentBlueprintSelectionDto(
    string Mode,
    string? BlueprintObjectId,
    string? DisplayName);
