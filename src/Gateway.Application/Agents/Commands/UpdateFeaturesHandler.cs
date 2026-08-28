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
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IUnitOfWork _unitOfWork;

    public UpdateFeaturesHandler(
        IAgentRepository agentRepository,
        IAuditEventRepository auditEventRepository,
        IPurviewPolicyClient purviewPolicyClient,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _auditEventRepository = auditEventRepository;
        _purviewPolicyClient = purviewPolicyClient;
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

        if (request.ObservabilityMode is not null ||
            request.Agent365ObservabilityEnabled is not null ||
            request.AzureMonitorExportEnabled is not null)
        {
            if (!ObservabilityModeExtensions.TryResolve(
                    request.ObservabilityMode,
                    request.Agent365ObservabilityEnabled,
                    request.AzureMonitorExportEnabled,
                    agent.FeatureConfiguration.ObservabilityMode,
                    out var observabilityMode))
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["ObservabilityMode"] =
                    ["Legacy and destination-specific observability settings must describe the same destinations."]
                });
            }

            agent.FeatureConfiguration.ObservabilityMode = observabilityMode;
        }

        var purviewEnabled = request.PurviewEnabled
            ?? agent.FeatureConfiguration.PurviewEnabled;
        var purviewMode = request.PurviewMode is null
            ? agent.FeatureConfiguration.PurviewMode
            : Enum.Parse<PurviewMode>(request.PurviewMode);
        if (purviewEnabled && !_purviewPolicyClient.IsEnabled)
        {
            throw new DomainException(
                "Purview cannot be enabled because it is not configured for this Gateway deployment.",
                Gateway.Contracts.ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        }

        agent.FeatureConfiguration.PurviewEnabled = purviewEnabled;
        agent.FeatureConfiguration.PurviewMode = purviewEnabled
            ? purviewMode ?? _purviewPolicyClient.DefaultMode
            : purviewMode;

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

        var destinations = agent.FeatureConfiguration.ObservabilityMode.ToDestinations();

        return new UpdateFeaturesResponse(
            agent.Id,
            new AgentFeaturesDto(
                agent.FeatureConfiguration.ObservabilityMode.ToString(),
                agent.FeatureConfiguration.PurviewEnabled,
                agent.FeatureConfiguration.PurviewMode?.ToString(),
                destinations.Agent365ObservabilityEnabled,
                destinations.AzureMonitorExportEnabled),
            agent.FeatureConfiguration.UpdatedAtUtc);
    }
}
