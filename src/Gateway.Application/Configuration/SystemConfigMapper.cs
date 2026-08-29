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
            config.ProvisioningMode,
            config.DefaultObservabilityMode,
            config.DefaultPurviewEnabled,
            config.DefaultPurviewMode,
            config.RetentionDaysActivityReceipts,
            config.RetentionDaysAuditEvents,
            config.RetentionDaysIdempotencyRecords,
            config.RetentionDaysOutboxMessages,
            config.RateLimitPerClient,
            config.RateLimitPerAgent,
            config.RateLimitGlobal,
            config.ReconciliationEnabled,
            config.ReconciliationIntervalHours,
            config.StuckTransitionTimeoutDays,
            config.UseGraphAgentRegistration,
            config.UseCliProvisioningFallback,
            destinations.Agent365ObservabilityEnabled,
            destinations.AzureMonitorExportEnabled,
            DefaultPromptShieldEnabled: config.DefaultPromptShieldEnabled);
    }
}
