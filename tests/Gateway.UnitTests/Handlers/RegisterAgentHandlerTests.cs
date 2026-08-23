using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class RegisterAgentHandlerTests
{
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly RegisterAgentHandler _handler;

    public RegisterAgentHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _provisioningJobRepository = Substitute.For<IProvisioningJobRepository>();
        _outboxRepository = Substitute.For<IOutboxRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _unitOfWork = Substitute.For<IUnitOfWork>();

        _handler = new RegisterAgentHandler(
            _agentRepository,
            _provisioningJobRepository,
            _outboxRepository,
            _auditEventRepository,
            _unitOfWork);
    }

    private static RegisterAgentCommand CreateValidCommand() =>
        new(
            ExternalAgentId: "agent-001",
            Name: "Test Agent",
            Description: "A test agent",
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            CallerObjectId: "caller-oid-001");

    [Fact]
    public async Task Handle_Should_ReturnResponse_When_AgentDoesNotExist()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        result.ExternalAgentId.Should().Be("agent-001");
        result.Name.Should().Be("Test Agent");
        result.Status.Should().Be(AgentStatus.Draft.ToString());
        result.AgentId.Should().NotBeEmpty();
        result.OperationId.Should().NotBeEmpty();
    }

    [Fact]
    public async Task Handle_Should_CreateAgentWithDraftStatus_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _agentRepository.Received(1).AddAsync(
            Arg.Is<AgentRegistration>(a =>
                a.Status == AgentStatus.Draft &&
                a.Name == "Test Agent" &&
                a.OwnerObjectId == "owner-oid-001" &&
                a.Environment == AgentEnvironment.Development),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateProvisioningJob_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _provisioningJobRepository.Received(1).AddAsync(
            Arg.Is<ProvisioningJob>(j =>
                j.Type == OperationType.ProvisionAgent &&
                j.Status == JobStatus.Pending &&
                j.Steps.Count > 0),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateOutboxMessage_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _outboxRepository.Received(1).AddAsync(
            Arg.Is<OutboxMessage>(m =>
                m.MessageType == "ProvisionAgent" &&
                m.Status == OutboxMessageStatus.Pending),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateAuditEvent_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(e =>
                e.EventType == "AgentRegistered" &&
                e.PerformedByObjectId == "caller-oid-001"),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CallSaveChangesExactlyOnce_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_ThrowConflictException_When_ExternalAgentIdAlreadyExists()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(true);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID);
    }

    [Fact]
    public async Task Handle_Should_NotCallSaveChanges_When_DuplicateDetected()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(true);

        var act = () => _handler.Handle(command, CancellationToken.None);
        await act.Should().ThrowAsync<ConflictException>();

        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }
}
