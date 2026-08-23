using FluentAssertions;
using Gateway.Domain.Enums;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Repositories;

public class ProvisioningJobRepositoryTests
{
    [Fact]
    public async Task AddAsync_And_GetByIdAsync_Should_ReturnJobWithSteps_When_JobWasAdded()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new ProvisioningJobRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var job = TestEntityFactory.CreateProvisioningJob(agent.Id, stepCount: 4);
        await repository.AddAsync(job, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var retrieved = await repository.GetByIdAsync(job.Id, CancellationToken.None);

        // Assert
        retrieved.Should().NotBeNull();
        retrieved!.Id.Should().Be(job.Id);
        retrieved.AgentRegistrationId.Should().Be(agent.Id);
        retrieved.Type.Should().Be(OperationType.ProvisionAgent);
        retrieved.Status.Should().Be(JobStatus.Pending);
        retrieved.Steps.Should().HaveCount(4);
    }

    [Fact]
    public async Task GetByIdAsync_Should_ReturnNull_When_JobDoesNotExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new ProvisioningJobRepository(context);

        // Act
        var result = await repository.GetByIdAsync(Guid.NewGuid(), CancellationToken.None);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public async Task GetByIdAsync_Should_ReturnStepsOrderedByOrderIndex_When_StepsExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new ProvisioningJobRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var job = TestEntityFactory.CreateProvisioningJob(agent.Id, stepCount: 5);
        await repository.AddAsync(job, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var retrieved = await repository.GetByIdAsync(job.Id, CancellationToken.None);

        // Assert
        retrieved.Should().NotBeNull();
        retrieved!.Steps.Should().HaveCount(5);
        retrieved.Steps.Select(s => s.OrderIndex).Should().BeInAscendingOrder();
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnAllJobsForAgent_When_MultipleJobsExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new ProvisioningJobRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var job1 = TestEntityFactory.CreateProvisioningJob(agent.Id, stepCount: 2);
        var job2 = TestEntityFactory.CreateProvisioningJob(agent.Id, type: OperationType.RetryProvisioning, stepCount: 1);
        await repository.AddAsync(job1, CancellationToken.None);
        await repository.AddAsync(job2, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetByAgentIdAsync(agent.Id, CancellationToken.None);

        // Assert
        results.Should().HaveCount(2);
        results.Should().AllSatisfy(j => j.AgentRegistrationId.Should().Be(agent.Id));
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnJobsDescendingByCreatedAtUtc_When_MultipleJobsExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new ProvisioningJobRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 3; i++)
        {
            var job = TestEntityFactory.CreateProvisioningJob(agent.Id, stepCount: 1);
            job.CreatedAtUtc = baseTime.AddHours(i);
            await repository.AddAsync(job, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetByAgentIdAsync(agent.Id, CancellationToken.None);

        // Assert
        results.Should().HaveCount(3);
        results.Should().BeInDescendingOrder(j => j.CreatedAtUtc);
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_ReturnEmpty_When_NoJobsExistForAgent()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new ProvisioningJobRepository(context);

        // Act
        var results = await repository.GetByAgentIdAsync(Guid.NewGuid(), CancellationToken.None);

        // Assert
        results.Should().BeEmpty();
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_NotReturnJobsForOtherAgents_When_MultipleAgentsHaveJobs()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new ProvisioningJobRepository(context);

        var agent1 = TestEntityFactory.CreateAgentRegistration();
        var agent2 = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent1, CancellationToken.None);
        await agentRepo.AddAsync(agent2, CancellationToken.None);

        var job1 = TestEntityFactory.CreateProvisioningJob(agent1.Id, stepCount: 1);
        var job2 = TestEntityFactory.CreateProvisioningJob(agent2.Id, stepCount: 1);
        await repository.AddAsync(job1, CancellationToken.None);
        await repository.AddAsync(job2, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetByAgentIdAsync(agent1.Id, CancellationToken.None);

        // Assert
        results.Should().HaveCount(1);
        results[0].Id.Should().Be(job1.Id);
    }

    [Fact]
    public async Task GetByAgentIdAsync_Should_IncludeStepsWithEachJob_When_JobsHaveSteps()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var agentRepo = new AgentRegistrationRepository(context);
        var repository = new ProvisioningJobRepository(context);

        var agent = TestEntityFactory.CreateAgentRegistration();
        await agentRepo.AddAsync(agent, CancellationToken.None);

        var job = TestEntityFactory.CreateProvisioningJob(agent.Id, stepCount: 3);
        await repository.AddAsync(job, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetByAgentIdAsync(agent.Id, CancellationToken.None);

        // Assert
        results.Should().HaveCount(1);
        results[0].Steps.Should().HaveCount(3);
        results[0].Steps.Select(s => s.OrderIndex).Should().BeInAscendingOrder();
    }
}
