namespace Gateway.Contracts.Dtos;

public record AgentFeaturesDto(
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode,
    bool? Agent365ObservabilityEnabled = null,
    bool? AzureMonitorExportEnabled = null);
