using Gateway.Application.Exceptions;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Configuration.Commands;

internal sealed class UpdateSystemConfigHandler : IRequestHandler<UpdateSystemConfigCommand, SystemConfigDto>
{
    private readonly ISystemConfigurationRepository _configRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public UpdateSystemConfigHandler(
        ISystemConfigurationRepository configRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _configRepository = configRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<SystemConfigDto> Handle(UpdateSystemConfigCommand request, CancellationToken cancellationToken)
    {
        var config = await _configRepository.GetAsync(cancellationToken)
            ?? throw new NotFoundException("SystemConfiguration", "singleton");

        if (request.ProvisioningMode is not null)
            config.ProvisioningMode = request.ProvisioningMode;
        if (request.DefaultObservabilityMode is not null)
            config.DefaultObservabilityMode = request.DefaultObservabilityMode;
        if (request.DefaultPurviewEnabled is not null)
            config.DefaultPurviewEnabled = request.DefaultPurviewEnabled.Value;
        if (request.DefaultPurviewMode is not null)
            config.DefaultPurviewMode = request.DefaultPurviewMode;
        if (request.RetentionDaysActivityReceipts is not null)
            config.RetentionDaysActivityReceipts = request.RetentionDaysActivityReceipts.Value;
        if (request.RetentionDaysAuditEvents is not null)
            config.RetentionDaysAuditEvents = request.RetentionDaysAuditEvents.Value;
        if (request.RetentionDaysIdempotencyRecords is not null)
            config.RetentionDaysIdempotencyRecords = request.RetentionDaysIdempotencyRecords.Value;
        if (request.RetentionDaysOutboxMessages is not null)
            config.RetentionDaysOutboxMessages = request.RetentionDaysOutboxMessages.Value;
        if (request.RateLimitPerClient is not null)
            config.RateLimitPerClient = request.RateLimitPerClient.Value;
        if (request.RateLimitPerAgent is not null)
            config.RateLimitPerAgent = request.RateLimitPerAgent.Value;
        if (request.RateLimitGlobal is not null)
            config.RateLimitGlobal = request.RateLimitGlobal.Value;
        if (request.ReconciliationEnabled is not null)
            config.ReconciliationEnabled = request.ReconciliationEnabled.Value;
        if (request.ReconciliationIntervalHours is not null)
            config.ReconciliationIntervalHours = request.ReconciliationIntervalHours.Value;
        if (request.StuckTransitionTimeoutDays is not null)
            config.StuckTransitionTimeoutDays = request.StuckTransitionTimeoutDays.Value;
        if (request.UseGraphAgentRegistration is not null)
            config.UseGraphAgentRegistration = request.UseGraphAgentRegistration.Value;
        if (request.UseCliProvisioningFallback is not null)
            config.UseCliProvisioningFallback = request.UseCliProvisioningFallback.Value;

        config.UpdatedAtUtc = DateTime.UtcNow;

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = "SystemConfigUpdated",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };

        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);
        await _unitOfWork.SaveChangesAsync(cancellationToken);

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
