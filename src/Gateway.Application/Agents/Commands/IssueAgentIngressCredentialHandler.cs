using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class IssueAgentIngressCredentialHandler
    : IRequestHandler<IssueAgentIngressCredentialCommand, IssueAgentIngressCredentialResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAgentIngressCredentialService _credentialService;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public IssueAgentIngressCredentialHandler(
        IAgentRepository agentRepository,
        IAgentIngressCredentialService credentialService,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _credentialService = credentialService;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<IssueAgentIngressCredentialResponse> Handle(
        IssueAgentIngressCredentialCommand request,
        CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken);
        if (agent is null || agent.IsDeleted || agent.Status == AgentStatus.Deleted)
        {
            throw new NotFoundException("AgentRegistration", request.AgentId);
        }

        if (agent.Status == AgentStatus.Deleting)
        {
            throw new InvalidStateTransitionException(agent.Status.ToString(), "IssueGatewayCredential");
        }

        var issuedAtUtc = DateTime.UtcNow;
        var issued = _credentialService.Issue(
            agent.Id,
            request.CallerObjectId,
            issuedAtUtc);

        agent.UpdatedAtUtc = issuedAtUtc;
        agent.UpdatedByObjectId = request.CallerObjectId;

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "GatewayCredentialIssued",
            PerformedByObjectId = request.CallerObjectId,
            Details = JsonSerializer.Serialize(new
            {
                credentialId = issued.Credential.Id,
                expiresAtUtc = issued.Credential.ExpiresAtUtc
            }),
            OccurredAtUtc = issuedAtUtc
        }, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new IssueAgentIngressCredentialResponse(
            agent.Id,
            agent.ExternalAgentId.Value,
            new AgentGatewayCredentialDto(
                issued.Credential.Id,
                issued.ApiKey,
                issued.Credential.ExpiresAtUtc));
    }
}
