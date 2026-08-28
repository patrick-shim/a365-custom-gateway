using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class RevokeAgentIngressCredentialHandler
    : IRequestHandler<RevokeAgentIngressCredentialCommand, RevokeAgentIngressCredentialResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAgentIngressCredentialService _credentialService;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public RevokeAgentIngressCredentialHandler(
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

    public async Task<RevokeAgentIngressCredentialResponse> Handle(
        RevokeAgentIngressCredentialCommand request,
        CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken);
        if (agent is null || agent.IsDeleted || agent.Status == AgentStatus.Deleted)
        {
            throw new NotFoundException("AgentRegistration", request.AgentId);
        }

        var revokedAtUtc = DateTime.UtcNow;
        var result = await _credentialService.RevokeAsync(
            agent.Id,
            request.CredentialId,
            revokedAtUtc,
            cancellationToken);

        if (result.Status == AgentIngressCredentialRevocationStatus.NotFound ||
            result.Credential is null)
        {
            throw new NotFoundException("AgentIngressCredential", request.CredentialId);
        }

        if (result.Status == AgentIngressCredentialRevocationStatus.LastUsableCredential)
        {
            throw new ConflictException(
                "Issue and deploy a replacement Gateway credential before revoking this registration's last usable credential.",
                ErrorCodes.AGENT_INGRESS_CREDENTIAL_LAST_USABLE);
        }

        var alreadyRevoked = result.Status == AgentIngressCredentialRevocationStatus.AlreadyRevoked;
        if (!alreadyRevoked)
        {
            agent.UpdatedAtUtc = revokedAtUtc;
            agent.UpdatedByObjectId = request.CallerObjectId;

            await _auditEventRepository.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "GatewayCredentialRevoked",
                PerformedByObjectId = request.CallerObjectId,
                Details = JsonSerializer.Serialize(new
                {
                    credentialId = result.Credential.KeyId,
                    revokedAtUtc = result.Credential.RevokedAtUtc
                }),
                OccurredAtUtc = revokedAtUtc
            }, cancellationToken);

            await _unitOfWork.SaveChangesAsync(cancellationToken);
        }

        return new RevokeAgentIngressCredentialResponse(
            agent.Id,
            ToDto(result.Credential),
            alreadyRevoked);
    }

    private static AgentIngressCredentialMetadataDto ToDto(
        AgentIngressCredentialMetadata credential) => new(
            credential.KeyId,
            credential.CreatedAtUtc,
            credential.ExpiresAtUtc,
            credential.RevokedAtUtc);
}
