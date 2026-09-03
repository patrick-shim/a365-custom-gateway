using FluentAssertions;
using Gateway.Application.Agents.Queries;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class ListAgentsHandlerTests
{
    private readonly IAgentRepository _agentRepository = Substitute.For<IAgentRepository>();
    private readonly IAiInteractionRepository _interactionRepository =
        Substitute.For<IAiInteractionRepository>();
    private readonly IActivityReceiptRepository _activityReceiptRepository =
        Substitute.For<IActivityReceiptRepository>();

    private static readonly DateTime Interacted = new(2026, 9, 1, 10, 0, 0, DateTimeKind.Utc);
    private static readonly DateTime Reported = new(2026, 9, 2, 15, 30, 0, DateTimeKind.Utc);

    [Fact]
    public async Task Handle_Should_ReportEachAgentsRealLastActivity()
    {
        var used = CreateAgent("used-agent");
        var neverUsed = CreateAgent("never-used-agent");
        GivenAgents(used, neverUsed);
        GivenInteractions((used.Id, Interacted));
        GivenActivities((used.Id, Reported));

        var response = await HandleAsync();

        response.Items.Should().HaveCount(2);
        response.Items[0].LastActivityAtUtc.Should().Be(
            Reported,
            "the list column was hardcoded to null before, so every agent read as never used");
        response.Items[1].LastActivityAtUtc.Should().BeNull();
    }

    [Fact]
    public async Task Handle_Should_LookUpEveryAgentOnThePageInOneQueryPerSource()
    {
        var first = CreateAgent("first-agent");
        var second = CreateAgent("second-agent");
        GivenAgents(first, second);
        GivenInteractions();
        GivenActivities();

        await HandleAsync();

        // One batched call per source, not one per row: the list page would otherwise
        // issue two round trips per agent and degrade with the size of the tenant.
        await _interactionRepository.Received(1).GetLatestReceivedAtUtcAsync(
            Arg.Is<IReadOnlyCollection<Guid>>(ids => ids.Contains(first.Id) && ids.Contains(second.Id)),
            Arg.Any<CancellationToken>());
        await _activityReceiptRepository.Received(1).GetLatestReceivedAtUtcAsync(
            Arg.Is<IReadOnlyCollection<Guid>>(ids => ids.Contains(first.Id) && ids.Contains(second.Id)),
            Arg.Any<CancellationToken>());
    }

    private async Task<Gateway.Contracts.Responses.AgentListResponse> HandleAsync()
    {
        var handler = new ListAgentsHandler(
            _agentRepository,
            _interactionRepository,
            _activityReceiptRepository);

        return await handler.Handle(
            new ListAgentsQuery(null, null, null),
            CancellationToken.None);
    }

    private void GivenAgents(params AgentRegistration[] agents)
    {
        _agentRepository
            .ListAsync(Arg.Any<AgentListFilter>(), Arg.Any<CancellationToken>())
            .Returns((agents.ToList(), agents.Length));
    }

    private void GivenInteractions(params (Guid AgentId, DateTime ReceivedAtUtc)[] rows)
    {
        _interactionRepository
            .GetLatestReceivedAtUtcAsync(Arg.Any<IReadOnlyCollection<Guid>>(), Arg.Any<CancellationToken>())
            .Returns(rows.ToDictionary(row => row.AgentId, row => row.ReceivedAtUtc));
    }

    private void GivenActivities(params (Guid AgentId, DateTime ReceivedAtUtc)[] rows)
    {
        _activityReceiptRepository
            .GetLatestReceivedAtUtcAsync(Arg.Any<IReadOnlyCollection<Guid>>(), Arg.Any<CancellationToken>())
            .Returns(rows.ToDictionary(row => row.AgentId, row => row.ReceivedAtUtc));
    }

    private static AgentRegistration CreateAgent(string externalAgentId) => new()
    {
        Id = Guid.NewGuid(),
        ExternalAgentId = new ExternalAgentId(externalAgentId),
        Name = externalAgentId,
        OwnerObjectId = Guid.NewGuid().ToString("D"),
        Environment = AgentEnvironment.Development,
        Status = AgentStatus.Active,
        CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
        CreatedByObjectId = "creator-object-id",
        UpdatedAtUtc = DateTime.UtcNow,
        UpdatedByObjectId = "updater-object-id",
        RowVersion = [1],
        FeatureConfiguration = new AgentFeatureConfiguration
        {
            ObservabilityMode = ObservabilityMode.GatewayOnly,
            UpdatedAtUtc = DateTime.UtcNow
        }
    };
}
