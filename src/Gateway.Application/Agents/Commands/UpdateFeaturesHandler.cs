using Gateway.Application.Exceptions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class UpdateFeaturesHandler : IRequestHandler<UpdateFeaturesCommand, UpdateFeaturesResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public UpdateFeaturesHandler(
        IAgentRepository agentRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<UpdateFeaturesResponse> Handle(UpdateFeaturesCommand request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);

        if (agent.Status is not AgentStatus.Active and not AgentStatus.Disabled)
        {
            throw new InvalidStateTransitionException(agent.Status.ToString(), "UpdateFeatures");
        }

        if (request.ObservabilityMode is not null)
            agent.FeatureConfiguration.ObservabilityMode = Enum.Parse<ObservabilityMode>(request.ObservabilityMode);

        if (request.PurviewEnabled is not null)
            agent.FeatureConfiguration.PurviewEnabled = request.PurviewEnabled.Value;

        if (request.PurviewMode is not null)
            agent.FeatureConfiguration.PurviewMode = Enum.Parse<PurviewMode>(request.PurviewMode);

        agent.FeatureConfiguration.UpdatedAtUtc = DateTime.UtcNow;
        agent.UpdatedAtUtc = DateTime.UtcNow;
        agent.UpdatedByObjectId = request.CallerObjectId;

        var auditEvent = new Domain.Entities.AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "FeaturesUpdated",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new UpdateFeaturesResponse(
            agent.Id,
            new AgentFeaturesDto(
                agent.FeatureConfiguration.ObservabilityMode.ToString(),
                agent.FeatureConfiguration.PurviewEnabled,
                agent.FeatureConfiguration.PurviewMode?.ToString()),
            agent.FeatureConfiguration.UpdatedAtUtc);
    }
}
