namespace Gateway.Contracts.Dtos;

public record AgentFeaturesDto(
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode,
    bool? Agent365ObservabilityEnabled = null,
    bool? AzureMonitorExportEnabled = null,
    bool? PromptShieldEnabled = null,
    PurviewDlpProfileSelectionDto? PurviewDlpProfile = null,
    bool PurviewEffectivelyEnabled = false,
    ProtectionReadinessDto? PurviewReadiness = null,
    bool PromptShieldEffectivelyEnabled = false,
    string? PromptShieldCapabilityStatus = null);
