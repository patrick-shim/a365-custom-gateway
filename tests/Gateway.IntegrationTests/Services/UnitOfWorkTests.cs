using FluentAssertions;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests.Services;

public class UnitOfWorkTests
{
    [Fact]
    public async Task SaveChangesAsync_Should_PersistAgent_When_AgentAddedViaRepository()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var agentRepo = new AgentRegistrationRepository(context);
        var unitOfWork = new UnitOfWork(context);

        var agent = TestEntityFactory.CreateAgentRegistration(
            externalAgentId: "uow-test-agent",
            name: "UoW Test Agent");

        await agentRepo.AddAsync(agent, CancellationToken.None);

        // Act
        var changeCount = await unitOfWork.SaveChangesAsync(CancellationToken.None);

        // Assert - verify changes persisted by opening a new context on the same database
        changeCount.Should().BeGreaterThan(0);

        await using var verifyContext = TestDbContextFactory.Create(dbName);
        var verifyRepo = new AgentRegistrationRepository(verifyContext);
        var retrieved = await verifyRepo.GetByIdAsync(agent.Id, CancellationToken.None);

        retrieved.Should().NotBeNull();
        retrieved!.Name.Should().Be("UoW Test Agent");
    }

    [Fact]
    public async Task SaveChangesAsync_Should_PersistMultipleEntities_When_AgentAndJobAndOutboxAdded()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var agentRepo = new AgentRegistrationRepository(context);
        var jobRepo = new ProvisioningJobRepository(context);
        var outboxRepo = new OutboxRepository(context);
        var unitOfWork = new UnitOfWork(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        var job = TestEntityFactory.CreateProvisioningJob(agent.Id, stepCount: 2);
        var outboxMsg = TestEntityFactory.CreateOutboxMessage();

        await agentRepo.AddAsync(agent, CancellationToken.None);
        await jobRepo.AddAsync(job, CancellationToken.None);
        await outboxRepo.AddAsync(outboxMsg, CancellationToken.None);

        // Act - single save for all operations
        var changeCount = await unitOfWork.SaveChangesAsync(CancellationToken.None);

        // Assert
        changeCount.Should().BeGreaterThan(0);

        await using var verifyContext = TestDbContextFactory.Create(dbName);
        var verifyAgentRepo = new AgentRegistrationRepository(verifyContext);
        var verifyJobRepo = new ProvisioningJobRepository(verifyContext);
        var verifyOutboxRepo = new OutboxRepository(verifyContext);

        var retrievedAgent = await verifyAgentRepo.GetByIdAsync(agent.Id, CancellationToken.None);
        var retrievedJob = await verifyJobRepo.GetByIdAsync(job.Id, CancellationToken.None);
        var retrievedOutbox = await verifyOutboxRepo.GetPendingAsync(10, CancellationToken.None);

        retrievedAgent.Should().NotBeNull();
        retrievedJob.Should().NotBeNull();
        retrievedJob!.Steps.Should().HaveCount(2);
        retrievedOutbox.Should().Contain(m => m.Id == outboxMsg.Id);
    }

    [Fact]
    public async Task SaveChangesAsync_Should_NotPersistUnsavedChanges_When_SaveNotCalled()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var agentRepo = new AgentRegistrationRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration(externalAgentId: "unsaved-agent");
        await agentRepo.AddAsync(agent, CancellationToken.None);

        // Do NOT call SaveChangesAsync

        // Assert - verify agent is not persisted in a new context
        await using var verifyContext = TestDbContextFactory.Create(dbName);
        var verifyRepo = new AgentRegistrationRepository(verifyContext);
        var retrieved = await verifyRepo.GetByIdAsync(agent.Id, CancellationToken.None);

        retrieved.Should().BeNull();
    }

    [Fact]
    public async Task SaveChangesAsync_Should_ReturnZero_When_NoChangesExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var unitOfWork = new UnitOfWork(context);

        // Act
        var changeCount = await unitOfWork.SaveChangesAsync(CancellationToken.None);

        // Assert
        changeCount.Should().Be(0);
    }

    [Fact]
    public async Task SaveChangesAsync_Should_PersistAgentWithAuditEvent_When_BothAdded()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var agentRepo = new AgentRegistrationRepository(context);
        var auditRepo = new AuditEventRepository(context);
        var unitOfWork = new UnitOfWork(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        var auditEvent = TestEntityFactory.CreateAuditEvent(
            agentRegistrationId: agent.Id,
            eventType: "AgentRegistered");

        await agentRepo.AddAsync(agent, CancellationToken.None);
        await auditRepo.AddAsync(auditEvent, CancellationToken.None);

        // Act
        await unitOfWork.SaveChangesAsync(CancellationToken.None);

        // Assert
        await using var verifyContext = TestDbContextFactory.Create(dbName);
        var verifyAuditRepo = new AuditEventRepository(verifyContext);

        var (events, _) = await verifyAuditRepo.GetByAgentIdAsync(
            agent.Id, 10, null, CancellationToken.None);
        events.Should().HaveCount(1);
        events[0].EventType.Should().Be("AgentRegistered");
    }

    [Fact]
    public async Task SaveChangesAsync_Should_TranslateOptimisticConcurrencyFailureToSafeConflict()
    {
        await using var context = new ConcurrencyFailureDbContext();
        var unitOfWork = new UnitOfWork(context);

        var action = () => unitOfWork.SaveChangesAsync(CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.CONCURRENCY_CONFLICT);
        exception.Which.Message.Should().NotContain(nameof(DbUpdateConcurrencyException));
        exception.Which.InnerException.Should().BeOfType<DbUpdateConcurrencyException>();
    }

    [Fact]
    public async Task AgentRegistrationRowVersion_Should_RemainTheRetrySerializationBoundary()
    {
        await using var context = TestDbContextFactory.Create();

        var rowVersion = context.Model
            .FindEntityType(typeof(AgentRegistration))!
            .FindProperty(nameof(AgentRegistration.RowVersion));

        rowVersion.Should().NotBeNull();
        rowVersion!.IsConcurrencyToken.Should().BeTrue();
        rowVersion.ValueGenerated.Should().Be(Microsoft.EntityFrameworkCore.Metadata.ValueGenerated.OnAddOrUpdate);
    }

    private sealed class ConcurrencyFailureDbContext()
        : GatewayDbContext(new DbContextOptionsBuilder<GatewayDbContext>().Options)
    {
        public override Task<int> SaveChangesAsync(CancellationToken cancellationToken = default) =>
            Task.FromException<int>(new DbUpdateConcurrencyException("raw provider failure"));
    }

}
