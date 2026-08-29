using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class UpdateFeaturesHandlerTests
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IUnitOfWork _unitOfWork;
    private readonly UpdateFeaturesHandler _handler;

    public UpdateFeaturesHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _purviewPolicyClient = Substitute.For<IPurviewPolicyClient>();
        _purviewPolicyClient.IsEnabled.Returns(true);
        _promptShieldClient = Substitute.For<IPromptShieldClient>();
        _promptShieldClient.IsEnabled.Returns(true);
        _unitOfWork = Substitute.For<IUnitOfWork>();
        _handler = new UpdateFeaturesHandler(
            _agentRepository,
            _auditEventRepository,
            _purviewPolicyClient,
            _promptShieldClient,
            _unitOfWork);
    }

    [Fact]
    public async Task Handle_Should_MergePartialDestinationUpdateWithStoredMode()
    {
        var agent = CreateAgent(ObservabilityMode.Agent365);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        var command = new UpdateFeaturesCommand(
            AgentId: agent.Id,
            ObservabilityMode: null,
            PurviewEnabled: null,
            PurviewMode: null,
            CallerObjectId: "caller-oid-001",
            Agent365ObservabilityEnabled: null,
            AzureMonitorExportEnabled: true);

        var result = await _handler.Handle(command, CancellationToken.None);

        agent.FeatureConfiguration.ObservabilityMode
            .Should().Be(ObservabilityMode.Agent365AzureMonitor);
        result.Features.Agent365ObservabilityEnabled.Should().BeTrue();
        result.Features.AzureMonitorExportEnabled.Should().BeTrue();
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldRejectPurviewBeforeMutation_WhenAdapterIsDisabled()
    {
        var agent = CreateAgent(ObservabilityMode.Agent365);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _purviewPolicyClient.IsEnabled.Returns(false);
        var command = new UpdateFeaturesCommand(
            agent.Id,
            ObservabilityMode: null,
            PurviewEnabled: true,
            PurviewMode: "Enforce",
            CallerObjectId: "caller-oid-001");

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        agent.FeatureConfiguration.PurviewEnabled.Should().BeFalse();
        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    private static AgentRegistration CreateAgent(ObservabilityMode observabilityMode)
    {
        var agentId = Guid.NewGuid();

        return new AgentRegistration
        {
            Id = agentId,
            ExternalAgentId = new ExternalAgentId("agent-001"),
            Name = "Test Agent",
            OwnerObjectId = "owner-oid-001",
            Environment = AgentEnvironment.Development,
            Status = AgentStatus.Active,
            CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
            UpdatedAtUtc = DateTime.UtcNow.AddDays(-1),
            CreatedByObjectId = "owner-oid-001",
            UpdatedByObjectId = "owner-oid-001",
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agentId,
                ObservabilityMode = observabilityMode,
                UpdatedAtUtc = DateTime.UtcNow.AddDays(-1)
            }
        };
    }
}
