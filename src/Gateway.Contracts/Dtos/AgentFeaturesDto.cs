namespace Gateway.Contracts.Dtos;

public record AgentFeaturesDto(
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode,
    bool? Agent365ObservabilityEnabled = null,
    bool? AzureMonitorExportEnabled = null,
    bool? PromptShieldEnabled = null,
    bool PurviewEffectivelyEnabled = false,
    bool PromptShieldEffectivelyEnabled = false,
    string? PurviewPolicyMode = null);
