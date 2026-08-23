using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class DisableAgentHandlerTests
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly DisableAgentHandler _handler;

    public DisableAgentHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _unitOfWork = Substitute.For<IUnitOfWork>();

        _handler = new DisableAgentHandler(
            _agentRepository,
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
    public async Task Handle_Should_ReturnAgentStateChangeResponse_When_AgentIsActive()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DisableAgentCommand(agent.Id, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        result.AgentId.Should().Be(agent.Id);
        result.Status.Should().Be(AgentStatus.Disabled.ToString());
    }

    [Fact]
    public async Task Handle_Should_ChangeStatusToDisabled_When_AgentIsActive()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DisableAgentCommand(agent.Id, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        agent.Status.Should().Be(AgentStatus.Disabled);
    }

    [Fact]
    public async Task Handle_Should_CreateAuditEvent_When_AgentDisabled()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DisableAgentCommand(agent.Id, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(e =>
                e.EventType == "AgentDisabled" &&
                e.PerformedByObjectId == "caller-oid-001" &&
                e.AgentRegistrationId == agent.Id),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CallSaveChanges_When_AgentDisabled()
    {
        var agent = CreateAgent(AgentStatus.Active);
        var command = new DisableAgentCommand(agent.Id, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_ThrowNotFoundException_When_AgentDoesNotExist()
    {
        var command = new DisableAgentCommand(Guid.NewGuid(), "caller-oid-001");

        _agentRepository.GetByIdAsync(command.AgentId, Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var act = () => _handler.Handle(command, CancellationToken.None);

        await act.Should().ThrowAsync<NotFoundException>();
    }

    [Theory]
    [InlineData(AgentStatus.Draft)]
    [InlineData(AgentStatus.Disabled)]
    [InlineData(AgentStatus.Provisioning)]
    [InlineData(AgentStatus.Failed)]
    [InlineData(AgentStatus.Deleting)]
    [InlineData(AgentStatus.Deleted)]
    public async Task Handle_Should_ThrowInvalidStateTransitionException_When_AgentIsNotActive(AgentStatus status)
    {
        var agent = CreateAgent(status);
        var command = new DisableAgentCommand(agent.Id, "caller-oid-001");

        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.CurrentState.Should().Be(status.ToString());
        exception.Which.AttemptedAction.Should().Be("Disable");
    }
}
