using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class DeleteAgentHandlerTests
{
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly DeleteAgentHandler _handler;

    public DeleteAgentHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _provisioningJobRepository = Substitute.For<IProvisioningJobRepository>();
        _outboxRepository = Substitute.For<IOutboxRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _unitOfWork = Substitute.For<IUnitOfWork>();

        _handler = new DeleteAgentHandler(
            _agentRepository,
            _provisioningJobRepository,
            _outboxRepository,
            _auditEventRepository,
            _unitOfWork);
    }

    private static AgentRegistration CreateAgent(AgentStatus status) =>
        new()
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId("agent-001"),
            Name = "Test Agent",
            OwnerObjectId = "owner-oid-001",
            Environment = AgentEnvironment.Development,
            Status = status,
            CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
            UpdatedAtUtc = DateTime.UtcNow.AddDays(-1),
            CreatedByObjectId = "owner-oid-001",
            UpdatedByObjectId = "owner-oid-001"
        };

    [Fact]
    public async Task Handle_Should_ReturnDeleteAgentResponse_When_AgentIsActive()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        result.AgentId.Should().Be(agent.Id);
        result.Status.Should().Be(AgentStatus.Deleting.ToString());
        result.OperationId.Should().NotBeEmpty();
        result.DeleteMicrosoftResources.Should().BeTrue();
    }

    [Fact]
    public async Task Handle_Should_KeepAgentUndeletedWhileDeletionIsPending()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, false, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        agent.Status.Should().Be(AgentStatus.Deleting);
        agent.IsDeleted.Should().BeFalse();
        agent.DeletedAtUtc.Should().BeNull();
    }

    [Fact]
    public async Task Handle_Should_CreateProvisioningJob_When_Deleted()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _provisioningJobRepository.Received(1).AddAsync(
            Arg.Is<ProvisioningJob>(j =>
                j.Type == OperationType.DeleteAgent &&
                j.Status == JobStatus.Pending),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateOutboxMessage_When_Deleted()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _outboxRepository.Received(1).AddAsync(
            Arg.Is<OutboxMessage>(m =>
                m.MessageType == "DeleteAgent" &&
                m.Status == OutboxMessageStatus.Pending),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_WriteSharedDeleteAgentMessage_When_DeletionIsRequested()
    {
        ProvisioningJob? createdJob = null;
        OutboxMessage? createdMessage = null;
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _provisioningJobRepository.AddAsync(
                Arg.Do<ProvisioningJob>(job => createdJob = job),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        _outboxRepository.AddAsync(
                Arg.Do<OutboxMessage>(message => createdMessage = message),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdJob.Should().NotBeNull();
        createdMessage.Should().NotBeNull();
        createdMessage!.MessageType.Should().Be("DeleteAgent");

        var payload = JsonSerializer.Deserialize<DeleteAgentMessage>(createdMessage.Payload);
        payload.Should().NotBeNull();
        payload!.AgentRegistrationId.Should().Be(agent.Id);
        payload.JobId.Should().Be(createdJob!.Id);
        payload.DeleteMicrosoftResources.Should().BeTrue();
    }

    [Fact]
    public async Task Handle_Should_CreateAuditEvent_When_DeletionIsRequested()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(e =>
                e.EventType == "AgentDeletionRequested" &&
                e.PerformedByObjectId == "caller-oid-001"),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CallSaveChangesExactlyOnce_When_Deleted()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_ThrowNotFoundException_When_AgentDoesNotExist()
    {
        var command = new DeleteAgentCommand(Guid.NewGuid(), true, "caller-oid-001");

        _agentRepository.GetByIdAsync(command.AgentId, Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var act = () => _handler.Handle(command, CancellationToken.None);

        await act.Should().ThrowAsync<NotFoundException>();
    }

    [Fact]
    public async Task Handle_Should_ThrowInvalidStateTransitionException_When_AgentIsAlreadyDeleting()
    {
        var agent = CreateAgent(AgentStatus.Deleting);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.CurrentState.Should().Be(AgentStatus.Deleting.ToString());
        exception.Which.AttemptedAction.Should().Be("Delete");
    }

    [Fact]
    public async Task Handle_Should_ThrowInvalidStateTransitionException_When_AgentIsAlreadyDeleted()
    {
        var agent = CreateAgent(AgentStatus.Deleted);
        var command = new DeleteAgentCommand(agent.Id, true, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.CurrentState.Should().Be(AgentStatus.Deleted.ToString());
        exception.Which.AttemptedAction.Should().Be("Delete");
    }

    [Fact]
    public async Task Handle_Should_Succeed_When_AgentIsDraftOrDisabledOrFailed()
    {
        // Non-Deleting/Deleted statuses should all be deletable
        foreach (var status in new[] { AgentStatus.Draft, AgentStatus.Disabled, AgentStatus.Failed, AgentStatus.Active })
        {
            var agent = CreateAgent(status);
            var command = new DeleteAgentCommand(agent.Id, false, "caller-oid-001");

            _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
                .Returns(agent);

            var result = await _handler.Handle(command, CancellationToken.None);

            result.Status.Should().Be(AgentStatus.Deleting.ToString());
        }
    }
}
