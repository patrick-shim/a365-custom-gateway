using FluentAssertions;
using Gateway.Application.Agents;
using Gateway.Domain.Interfaces;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class AgentLastActivityTests
{
    private readonly IAiInteractionRepository _interactionRepository =
        Substitute.For<IAiInteractionRepository>();
    private readonly IActivityReceiptRepository _activityReceiptRepository =
        Substitute.For<IActivityReceiptRepository>();

    private static readonly Guid AgentId = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid OtherAgentId = Guid.Parse("22222222-2222-4222-8222-222222222222");

    private static readonly DateTime Earlier = new(2026, 9, 1, 10, 0, 0, DateTimeKind.Utc);
    private static readonly DateTime Later = new(2026, 9, 2, 15, 30, 0, DateTimeKind.Utc);

    [Fact]
    public async Task ResolveAsync_TakesTheLaterOfInteractionAndActivity()
    {
        GivenInteractions((AgentId, Earlier));
        GivenActivities((AgentId, Later));

        var latest = await ResolveAsync(AgentId);

        AgentLastActivity.For(latest, AgentId).Should().Be(Later);
    }

    [Fact]
    public async Task ResolveAsync_TakesTheInteractionWhenItIsTheLaterOne()
    {
        GivenInteractions((AgentId, Later));
        GivenActivities((AgentId, Earlier));

        var latest = await ResolveAsync(AgentId);

        AgentLastActivity.For(latest, AgentId).Should().Be(Later);
    }

    [Fact]
    public async Task ResolveAsync_UsesWhicheverSourceHasData()
    {
        GivenInteractions();
        GivenActivities((AgentId, Later));

        var latest = await ResolveAsync(AgentId);

        AgentLastActivity.For(latest, AgentId).Should().Be(Later);
    }

    [Fact]
    public async Task ResolveAsync_ReportsNullForAnAgentThatWasNeverCalled()
    {
        GivenInteractions((OtherAgentId, Later));
        GivenActivities((OtherAgentId, Later));

        var latest = await ResolveAsync(AgentId, OtherAgentId);

        AgentLastActivity.For(latest, AgentId).Should().BeNull(
            "an agent with no interactions and no activities has never been used, "
            + "and a default date would read as a real timestamp");
    }

    [Fact]
    public async Task ResolveAsync_KeepsAgentsIndependent()
    {
        GivenInteractions((AgentId, Earlier));
        GivenActivities((OtherAgentId, Later));

        var latest = await ResolveAsync(AgentId, OtherAgentId);

        AgentLastActivity.For(latest, AgentId).Should().Be(Earlier);
        AgentLastActivity.For(latest, OtherAgentId).Should().Be(Later);
    }

    [Fact]
    public async Task ResolveAsync_SkipsTheQueriesEntirelyForAnEmptyPage()
    {
        var latest = await AgentLastActivity.ResolveAsync(
            _interactionRepository,
            _activityReceiptRepository,
            Array.Empty<Guid>(),
            CancellationToken.None);

        latest.Should().BeEmpty();

        await _interactionRepository.DidNotReceiveWithAnyArgs()
            .GetLatestReceivedAtUtcAsync(default!, default);
        await _activityReceiptRepository.DidNotReceiveWithAnyArgs()
            .GetLatestReceivedAtUtcAsync(default!, default);
    }

    private Task<IReadOnlyDictionary<Guid, DateTime>> ResolveAsync(params Guid[] agentRegistrationIds)
    {
        return AgentLastActivity.ResolveAsync(
            _interactionRepository,
            _activityReceiptRepository,
            agentRegistrationIds,
            CancellationToken.None);
    }

    private void GivenInteractions(params (Guid AgentId, DateTime ReceivedAtUtc)[] rows)
    {
        _interactionRepository
            .GetLatestReceivedAtUtcAsync(Arg.Any<IReadOnlyCollection<Guid>>(), Arg.Any<CancellationToken>())
            .Returns(ToDictionary(rows));
    }

    private void GivenActivities(params (Guid AgentId, DateTime ReceivedAtUtc)[] rows)
    {
        _activityReceiptRepository
            .GetLatestReceivedAtUtcAsync(Arg.Any<IReadOnlyCollection<Guid>>(), Arg.Any<CancellationToken>())
            .Returns(ToDictionary(rows));
    }

    private static IReadOnlyDictionary<Guid, DateTime> ToDictionary(
        (Guid AgentId, DateTime ReceivedAtUtc)[] rows)
    {
        return rows.ToDictionary(row => row.AgentId, row => row.ReceivedAtUtc);
    }
}
