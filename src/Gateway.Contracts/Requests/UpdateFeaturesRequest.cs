namespace Gateway.Contracts.Requests;

public record UpdateFeaturesRequest(
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode);
