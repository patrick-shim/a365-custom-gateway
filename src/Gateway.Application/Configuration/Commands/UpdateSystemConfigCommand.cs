using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Configuration.Commands;

public record UpdateSystemConfigCommand(
    string? DefaultObservabilityMode,
    int? RetentionDaysIdempotencyRecords,
    int? RateLimitPerClient,
    int? RateLimitPerAgent,
    int? RateLimitGlobal,
    string CallerObjectId,
    bool? DefaultAgent365ObservabilityEnabled = null,
    bool? DefaultAzureMonitorExportEnabled = null,
    bool? DefaultPromptShieldEnabled = null,
    Guid? IdempotencyKey = null,
    string? ExpectedRowVersion = null,
    Guid? CallerTenantId = null,
    Guid? CorrelationId = null) : IRequest<SystemConfigDto>;
