namespace Gateway.Domain.Enums;

public readonly record struct ObservabilityDestinations(
    bool Agent365ObservabilityEnabled,
    bool AzureMonitorExportEnabled);

public static class ObservabilityModeExtensions
{
    public static ObservabilityDestinations ToDestinations(this ObservabilityMode mode) => mode switch
    {
        ObservabilityMode.Disabled => new(false, false),
        ObservabilityMode.GatewayOnly => new(false, true),
        ObservabilityMode.Agent365 => new(true, false),
        ObservabilityMode.Agent365AzureMonitor => new(true, true),
        _ => throw new ArgumentOutOfRangeException(nameof(mode), mode, "Unknown observability mode.")
    };

    public static ObservabilityMode FromDestinations(
        bool agent365ObservabilityEnabled,
        bool azureMonitorExportEnabled) =>
        (agent365ObservabilityEnabled, azureMonitorExportEnabled) switch
        {
            (false, false) => ObservabilityMode.Disabled,
            (false, true) => ObservabilityMode.GatewayOnly,
            (true, false) => ObservabilityMode.Agent365,
            (true, true) => ObservabilityMode.Agent365AzureMonitor
        };

    public static bool TryResolve(
        string? legacyMode,
        bool? agent365ObservabilityEnabled,
        bool? azureMonitorExportEnabled,
        ObservabilityMode fallbackMode,
        out ObservabilityMode resolvedMode)
    {
        var baselineMode = fallbackMode;

        if (legacyMode is not null &&
            (!Enum.TryParse(legacyMode, ignoreCase: false, out baselineMode) ||
             !Enum.IsDefined(baselineMode)))
        {
            resolvedMode = default;
            return false;
        }

        var baseline = baselineMode.ToDestinations();

        if (legacyMode is not null &&
            ((agent365ObservabilityEnabled.HasValue &&
              agent365ObservabilityEnabled.Value != baseline.Agent365ObservabilityEnabled) ||
             (azureMonitorExportEnabled.HasValue &&
              azureMonitorExportEnabled.Value != baseline.AzureMonitorExportEnabled)))
        {
            resolvedMode = default;
            return false;
        }

        resolvedMode = FromDestinations(
            agent365ObservabilityEnabled ?? baseline.Agent365ObservabilityEnabled,
            azureMonitorExportEnabled ?? baseline.AzureMonitorExportEnabled);

        return true;
    }
}
