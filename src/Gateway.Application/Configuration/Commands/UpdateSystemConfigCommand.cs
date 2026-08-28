using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Configuration.Commands;

public record UpdateSystemConfigCommand(
    string? ProvisioningMode,
    string? DefaultObservabilityMode,
    bool? DefaultPurviewEnabled,
    string? DefaultPurviewMode,
    int? RetentionDaysActivityReceipts,
    int? RetentionDaysAuditEvents,
    int? RetentionDaysIdempotencyRecords,
    int? RetentionDaysOutboxMessages,
    int? RateLimitPerClient,
    int? RateLimitPerAgent,
    int? RateLimitGlobal,
    bool? ReconciliationEnabled,
    int? ReconciliationIntervalHours,
    int? StuckTransitionTimeoutDays,
    bool? UseGraphAgentRegistration,
    bool? UseCliProvisioningFallback,
    string CallerObjectId,
    bool? DefaultAgent365ObservabilityEnabled = null,
    bool? DefaultAzureMonitorExportEnabled = null) : IRequest<SystemConfigDto>;
