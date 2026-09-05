using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public record UpdateFeaturesRequest(
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode,
    bool? Agent365ObservabilityEnabled = null,
    bool? AzureMonitorExportEnabled = null,
    bool? PromptShieldEnabled = null,
    PurviewDlpProfileSelectionDto? PurviewDlpProfile = null,
    Guid? IdempotencyKey = null,
    string? ExpectedRowVersion = null);
