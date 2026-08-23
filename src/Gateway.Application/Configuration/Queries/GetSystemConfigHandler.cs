using Gateway.Application.Exceptions;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Configuration.Queries;

internal sealed class GetSystemConfigHandler : IRequestHandler<GetSystemConfigQuery, SystemConfigDto>
{
    private readonly ISystemConfigurationRepository _configRepository;

    public GetSystemConfigHandler(ISystemConfigurationRepository configRepository)
    {
        _configRepository = configRepository;
    }

    public async Task<SystemConfigDto> Handle(GetSystemConfigQuery request, CancellationToken cancellationToken)
    {
        var config = await _configRepository.GetAsync(cancellationToken)
            ?? throw new NotFoundException("SystemConfiguration", "singleton");

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
            config.UseCliProvisioningFallback);
    }
}
