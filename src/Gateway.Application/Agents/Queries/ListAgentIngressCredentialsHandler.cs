using Gateway.Application.Exceptions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class ListAgentIngressCredentialsHandler
    : IRequestHandler<ListAgentIngressCredentialsQuery, AgentIngressCredentialListResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAgentIngressCredentialService _credentialService;

    public ListAgentIngressCredentialsHandler(
        IAgentRepository agentRepository,
        IAgentIngressCredentialService credentialService)
    {
        _agentRepository = agentRepository;
        _credentialService = credentialService;
    }

    public async Task<AgentIngressCredentialListResponse> Handle(
        ListAgentIngressCredentialsQuery request,
        CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken);
        if (agent is null || agent.IsDeleted || agent.Status == AgentStatus.Deleted)
        {
            throw new NotFoundException("AgentRegistration", request.AgentId);
        }

        var credentials = await _credentialService.ListAsync(agent.Id, cancellationToken);
        return new AgentIngressCredentialListResponse(
            agent.Id,
            credentials.Select(ToDto).ToList());
    }

    private static AgentIngressCredentialMetadataDto ToDto(
        AgentIngressCredentialMetadata credential) => new(
            credential.KeyId,
            credential.CreatedAtUtc,
            credential.ExpiresAtUtc,
            credential.RevokedAtUtc);
}
