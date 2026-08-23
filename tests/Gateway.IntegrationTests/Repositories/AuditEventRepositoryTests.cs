using System.Text;
using FluentAssertions;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Repositories;

public class AuditEventRepositoryTests
{
    [Fact]
    public async Task AddAsync_And_GetByAgentIdAsync_Should_ReturnEvent_When_EventWasAdded()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new AuditEventRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var auditEvent = TestEntityFactory.CreateAuditEvent(
            agentRegistrationId: agent.Id,
            eventType: "AgentRegistered");
        await repository.AddAsync(auditEvent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var (items, nextCursor) = await repository.GetByAgentIdAsync(
            agent.Id, 10, null, CancellationToken.None);

        // Assert
        items.Should().HaveCount(1);
        items[0].Id.Should().Be(auditEvent.Id);
        items[0].EventType.Should().Be("AgentRegistered");
        items[0].AgentRegistrationId.Should().Be(agent.Id);
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnEventsInDescendingOrder_When_MultipleEventsExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new AuditEventRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 5; i++)
        {
            var evt = TestEntityFactory.CreateAuditEvent(
                agentRegistrationId: agent.Id,
                eventType: $"Event{i}",
                occurredAtUtc: baseTime.AddMinutes(i));
            await repository.AddAsync(evt, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Act
        var (items, _) = await repository.GetByAgentIdAsync(
            agent.Id, 10, null, CancellationToken.None);

        // Assert
        items.Should().HaveCount(5);
        items.Should().BeInDescendingOrder(e => e.OccurredAtUtc);
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnCursor_When_MoreItemsExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new AuditEventRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 5; i++)
        {
            var evt = TestEntityFactory.CreateAuditEvent(
                agentRegistrationId: agent.Id,
                occurredAtUtc: baseTime.AddMinutes(i));
            await repository.AddAsync(evt, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Act - request 3 items (less than total 5)
        var (items, nextCursor) = await repository.GetByAgentIdAsync(
            agent.Id, 3, null, CancellationToken.None);

        // Assert
        items.Should().HaveCount(3);
        nextCursor.Should().NotBeNull();

        // Verify cursor contains the last item's data
        var decodedCursor = Encoding.UTF8.GetString(Convert.FromBase64String(nextCursor!));
        decodedCursor.Should().Contain(items[^1].Id.ToString());
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnNextPage_When_CursorProvided()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new AuditEventRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 5; i++)
        {
            var evt = TestEntityFactory.CreateAuditEvent(
                agentRegistrationId: agent.Id,
                occurredAtUtc: baseTime.AddMinutes(i));
            await repository.AddAsync(evt, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Get first page
        var (firstPage, cursor) = await repository.GetByAgentIdAsync(
            agent.Id, 3, null, CancellationToken.None);

        // Act - get second page using cursor
        var (secondPage, nextCursor) = await repository.GetByAgentIdAsync(
            agent.Id, 3, cursor, CancellationToken.None);

        // Assert
        secondPage.Should().HaveCount(2);
        nextCursor.Should().BeNull(); // No more pages (2 < limit of 3)

        // Second page should be chronologically before first page (descending)
        secondPage.Should().BeInDescendingOrder(e => e.OccurredAtUtc);
        secondPage[0].OccurredAtUtc.Should().BeBefore(firstPage[^1].OccurredAtUtc);
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnNullCursor_When_AllItemsFit()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new AuditEventRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var evt = TestEntityFactory.CreateAuditEvent(agentRegistrationId: agent.Id);
        await repository.AddAsync(evt, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var (items, nextCursor) = await repository.GetByAgentIdAsync(
            agent.Id, 10, null, CancellationToken.None);

        // Assert
        items.Should().HaveCount(1);
        nextCursor.Should().BeNull();
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_FilterByAgentId_When_MultipleAgentsHaveEvents()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new AuditEventRepository(context);

        var agent1 = TestEntityFactory.CreateAgentRegistration();
        var agent2 = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent1, CancellationToken.None);
        await agentRepo.AddAsync(agent2, CancellationToken.None);

        var event1 = TestEntityFactory.CreateAuditEvent(
            agentRegistrationId: agent1.Id, eventType: "Agent1Event");
        var event2 = TestEntityFactory.CreateAuditEvent(
            agentRegistrationId: agent2.Id, eventType: "Agent2Event");
        var event3 = TestEntityFactory.CreateAuditEvent(
            agentRegistrationId: agent1.Id, eventType: "Agent1Event2");

        await repository.AddAsync(event1, CancellationToken.None);
        await repository.AddAsync(event2, CancellationToken.None);
        await repository.AddAsync(event3, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var (items, _) = await repository.GetByAgentIdAsync(
            agent1.Id, 10, null, CancellationToken.None);

        // Assert
        items.Should().HaveCount(2);
        items.Should().AllSatisfy(e => e.AgentRegistrationId.Should().Be(agent1.Id));
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnEmpty_When_NoEventsExistForAgent()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AuditEventRepository(context);

        // Act
        var (items, nextCursor) = await repository.GetByAgentIdAsync(
            Guid.NewGuid(), 10, null, CancellationToken.None);

        // Assert
        items.Should().BeEmpty();
        nextCursor.Should().BeNull();
    }
}
