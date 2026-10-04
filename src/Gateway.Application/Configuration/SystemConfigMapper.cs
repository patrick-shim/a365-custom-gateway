using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;

namespace Gateway.Application.Configuration;

internal static class SystemConfigMapper
{
    public static SystemConfigDto ToDto(SystemConfiguration config)
    {
        if (!Enum.TryParse<ObservabilityMode>(
                config.DefaultObservabilityMode,
                ignoreCase: false,
                out var observabilityMode) ||
            !Enum.IsDefined(observabilityMode))
        {
            throw new InvalidOperationException("The stored default observability mode is invalid.");
        }

        var destinations = observabilityMode.ToDestinations();

        return new SystemConfigDto(
            "Automatic",
            config.DefaultObservabilityMode,
            config.RetentionDaysIdempotencyRecords,
            config.RateLimitPerClient,
            config.RateLimitPerAgent,
            config.RateLimitGlobal,
            destinations.Agent365ObservabilityEnabled,
            destinations.AzureMonitorExportEnabled,
            DefaultPromptShieldEnabled: config.DefaultPromptShieldEnabled,
            RowVersion: Protection.ProtectionRowVersion.Encode(
                config.RowVersion,
                config.Id,
                config.UpdatedAtUtc));
    }
}
