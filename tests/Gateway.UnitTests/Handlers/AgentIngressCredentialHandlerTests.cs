using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Queries;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class AgentIngressCredentialHandlerTests
{
    private const string CallerObjectId = "admin-object-id";

    private readonly IAgentRepository _agentRepository = Substitute.For<IAgentRepository>();
    private readonly IAgentIngressCredentialService _credentialService =
        Substitute.For<IAgentIngressCredentialService>();
    private readonly IAuditEventRepository _auditEventRepository =
        Substitute.For<IAuditEventRepository>();
    private readonly IUnitOfWork _unitOfWork = Substitute.For<IUnitOfWork>();

    [Fact]
    public async Task Issue_ShouldAddCredentialAndAuditInOneUnitOfWork()
    {
        var agent = CreateAgent();
        const string rawApiKey = "a365gw_v1_test-key-material";
        var credential = CreateCredential(agent.Id);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _credentialService.Issue(agent.Id, CallerObjectId, Arg.Any<DateTime>())
            .Returns(new IssuedAgentIngressCredential(credential, rawApiKey));
        var handler = new IssueAgentIngressCredentialHandler(
            _agentRepository,
            _credentialService,
            _auditEventRepository,
            _unitOfWork);

        var result = await handler.Handle(
            new IssueAgentIngressCredentialCommand(agent.Id, CallerObjectId),
            CancellationToken.None);

        result.GatewayCredential.ApiKey.Should().Be(rawApiKey);
        result.GatewayCredential.KeyId.Should().Be(credential.Id);
        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(auditEvent =>
                auditEvent.AgentRegistrationId == agent.Id &&
                auditEvent.EventType == "GatewayCredentialIssued" &&
                auditEvent.PerformedByObjectId == CallerObjectId &&
                auditEvent.Details != null &&
                auditEvent.Details.Contains(credential.Id.ToString(), StringComparison.OrdinalIgnoreCase) &&
                !auditEvent.Details.Contains(rawApiKey, StringComparison.Ordinal)),
            Arg.Any<CancellationToken>());
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
        agent.UpdatedByObjectId.Should().Be(CallerObjectId);
    }

    [Fact]
    public async Task Issue_ShouldRejectDeletingAgentBeforeGeneratingCredential()
    {
        var agent = CreateAgent(AgentStatus.Deleting);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        var handler = new IssueAgentIngressCredentialHandler(
            _agentRepository,
            _credentialService,
            _auditEventRepository,
            _unitOfWork);

        var action = () => handler.Handle(
            new IssueAgentIngressCredentialCommand(agent.Id, CallerObjectId),
            CancellationToken.None);

        await action.Should().ThrowAsync<InvalidStateTransitionException>();
        _credentialService.DidNotReceiveWithAnyArgs().Issue(default, default!, default);
        await _unitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Revoke_ShouldRejectLastUsableCredentialWithoutAuditOrSave()
    {
        var agent = CreateAgent();
        var credential = CreateMetadata();
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _credentialService.RevokeAsync(
                agent.Id,
                credential.KeyId,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(new AgentIngressCredentialRevocationResult(
                AgentIngressCredentialRevocationStatus.LastUsableCredential,
                credential));
        var handler = new RevokeAgentIngressCredentialHandler(
            _agentRepository,
            _credentialService,
            _auditEventRepository,
            _unitOfWork);

        var action = () => handler.Handle(
            new RevokeAgentIngressCredentialCommand(
                agent.Id,
                credential.KeyId,
                CallerObjectId),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_INGRESS_CREDENTIAL_LAST_USABLE);
        await _auditEventRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await _unitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Revoke_ShouldAuditNamedCredentialAndCommitOnce()
    {
        var agent = CreateAgent();
        var credential = CreateMetadata(revokedAtUtc: DateTime.UtcNow);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _credentialService.RevokeAsync(
                agent.Id,
                credential.KeyId,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(new AgentIngressCredentialRevocationResult(
                AgentIngressCredentialRevocationStatus.Revoked,
                credential));
        var handler = new RevokeAgentIngressCredentialHandler(
            _agentRepository,
            _credentialService,
            _auditEventRepository,
            _unitOfWork);

        var result = await handler.Handle(
            new RevokeAgentIngressCredentialCommand(
                agent.Id,
                credential.KeyId,
                CallerObjectId),
            CancellationToken.None);

        result.Credential.KeyId.Should().Be(credential.KeyId);
        result.AlreadyRevoked.Should().BeFalse();
        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(auditEvent =>
                auditEvent.EventType == "GatewayCredentialRevoked" &&
                auditEvent.AgentRegistrationId == agent.Id &&
                auditEvent.Details != null &&
                auditEvent.Details.Contains(credential.KeyId.ToString(), StringComparison.OrdinalIgnoreCase)),
            Arg.Any<CancellationToken>());
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task List_ShouldReturnOnlySafeMetadataForRouteAgent()
    {
        var agent = CreateAgent();
        var credential = CreateMetadata();
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _credentialService.ListAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([credential]);
        var handler = new ListAgentIngressCredentialsHandler(
            _agentRepository,
            _credentialService);

        var result = await handler.Handle(
            new ListAgentIngressCredentialsQuery(agent.Id),
            CancellationToken.None);

        var item = result.Items.Should().ContainSingle().Subject;
        item.KeyId.Should().Be(credential.KeyId);
        typeof(Gateway.Contracts.Dtos.AgentIngressCredentialMetadataDto)
            .GetProperties()
            .Select(property => property.Name)
            .Should().NotContain(["ApiKey", "SecretHash", "SecretSalt"]);
    }

    private static AgentRegistration CreateAgent(
        AgentStatus status = AgentStatus.Active) => new()
    {
        Id = Guid.NewGuid(),
        ExternalAgentId = new ExternalAgentId($"rotation-agent-{Guid.NewGuid():N}"),
        Name = "Rotation agent",
        OwnerObjectId = "owner-object-id",
        Environment = AgentEnvironment.Development,
        Status = status,
        CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
        UpdatedAtUtc = DateTime.UtcNow.AddDays(-1),
        CreatedByObjectId = "creator-object-id",
        UpdatedByObjectId = "creator-object-id"
    };

    private static AgentIngressCredential CreateCredential(Guid agentId) => new()
    {
        Id = Guid.NewGuid(),
        AgentRegistrationId = agentId,
        FormatVersion = 1,
        HashAlgorithm = "SHA-256",
        SecretSalt = new byte[32],
        SecretHash = new byte[32],
        CreatedAtUtc = DateTime.UtcNow,
        CreatedByObjectId = CallerObjectId,
        ExpiresAtUtc = DateTime.UtcNow.AddDays(365)
    };

    private static AgentIngressCredentialMetadata CreateMetadata(
        DateTime? revokedAtUtc = null) => new(
            Guid.NewGuid(),
            DateTime.UtcNow.AddDays(-1),
            DateTime.UtcNow.AddDays(364),
            revokedAtUtc);
}
