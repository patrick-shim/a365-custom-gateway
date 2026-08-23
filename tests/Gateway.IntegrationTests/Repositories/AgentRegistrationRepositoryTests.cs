using System.Globalization;
using System.Text;
using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Repositories;

public class AgentRegistrationRepositoryTests
{
    [Fact]
    public async Task AddAsync_And_GetByIdAsync_Should_ReturnAgent_When_AgentWasAdded()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);
        var agent = TestEntityFactory.CreateAgentRegistration(
            externalAgentId: "test-agent-001",
            name: "My Test Agent",
            environment: AgentEnvironment.Production,
            status: AgentStatus.Active);

        // Act
        await repository.AddAsync(agent, CancellationToken.None);
        await context.SaveChangesAsync();

        var retrieved = await repository.GetByIdAsync(agent.Id, CancellationToken.None);

        // Assert
        retrieved.Should().NotBeNull();
        retrieved!.Id.Should().Be(agent.Id);
        retrieved.ExternalAgentId.Should().Be(new ExternalAgentId("test-agent-001"));
        retrieved.Name.Should().Be("My Test Agent");
        retrieved.Environment.Should().Be(AgentEnvironment.Production);
        retrieved.Status.Should().Be(AgentStatus.Active);
        retrieved.OwnerObjectId.Should().Be(agent.OwnerObjectId);
        retrieved.Description.Should().Be(agent.Description);
        retrieved.CreatedAtUtc.Should().Be(agent.CreatedAtUtc);
        retrieved.FeatureConfiguration.Should().NotBeNull();
        retrieved.FeatureConfiguration.Id.Should().Be(agent.FeatureConfiguration.Id);
    }

    [Fact]
    public async Task GetByIdAsync_Should_ReturnNull_When_AgentDoesNotExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);

        // Act
        var result = await repository.GetByIdAsync(Guid.NewGuid(), CancellationToken.None);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public async Task GetByExternalAgentIdAsync_Should_ReturnAgent_When_ExternalAgentIdExists()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);
        var agent = TestEntityFactory.CreateAgentRegistration(externalAgentId: "ext-agent-lookup");

        await repository.AddAsync(agent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await repository.GetByExternalAgentIdAsync("ext-agent-lookup", CancellationToken.None);

        // Assert
        result.Should().NotBeNull();
        result!.Id.Should().Be(agent.Id);
        result.ExternalAgentId.Value.Should().Be("ext-agent-lookup");
        result.FeatureConfiguration.Should().NotBeNull();
    }

    [Fact]
    public async Task GetByExternalAgentIdAsync_Should_ReturnNull_When_ExternalAgentIdDoesNotExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);

        // Act
        var result = await repository.GetByExternalAgentIdAsync("nonexistent-agent", CancellationToken.None);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public async Task GetByExternalClientIdAsync_Should_ReturnAgent_When_ExternalClientIdExists()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);
        var clientId = Guid.NewGuid().ToString();
        var agent = TestEntityFactory.CreateAgentRegistration(externalClientId: clientId);

        await repository.AddAsync(agent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await repository.GetByExternalClientIdAsync(clientId, CancellationToken.None);

        // Assert
        result.Should().NotBeNull();
        result!.ExternalClientId.Should().Be(clientId);
    }

    [Fact]
    public async Task ExistsAsync_Should_ReturnTrue_When_ExternalAgentIdExists()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);
        var agent = TestEntityFactory.CreateAgentRegistration(externalAgentId: "exists-check-agent");

        await repository.AddAsync(agent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await repository.ExistsAsync("exists-check-agent", CancellationToken.None);

        // Assert
        result.Should().BeTrue();
    }

    [Fact]
    public async Task ExistsAsync_Should_ReturnFalse_When_ExternalAgentIdDoesNotExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);

        // Act
        var result = await repository.ExistsAsync("no-such-agent", CancellationToken.None);

        // Assert
        result.Should().BeFalse();
    }

    [Fact]
    public async Task ListAsync_Should_ReturnFirstPage_When_PaginatedWithLimit()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 5; i++)
        {
            var agent = TestEntityFactory.CreateAgentRegistration(
                createdAtUtc: baseTime.AddMinutes(i));
            await repository.AddAsync(agent, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        var filter = new AgentListFilter(null, null, null, 3, null);

        // Act
        var (items, totalCount) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().HaveCount(3);
        totalCount.Should().Be(5);
        items.Should().BeInAscendingOrder(a => a.CreatedAtUtc);
    }

    [Fact]
    public async Task ListAsync_Should_ReturnNextPage_When_CursorProvided()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var agents = new List<AgentRegistration>();
        for (int i = 0; i < 5; i++)
        {
            var agent = TestEntityFactory.CreateAgentRegistration(
                createdAtUtc: baseTime.AddMinutes(i));
            agents.Add(agent);
            await repository.AddAsync(agent, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Get first page
        var firstFilter = new AgentListFilter(null, null, null, 3, null);
        var (firstPage, _) = await repository.ListAsync(firstFilter, CancellationToken.None);

        // Build cursor from last item of first page (Base64-encoded CreatedAtUtc|Id)
        var lastItem = firstPage[^1];
        var cursorString = $"{lastItem.CreatedAtUtc:O}|{lastItem.Id}";
        var cursor = Convert.ToBase64String(Encoding.UTF8.GetBytes(cursorString));

        var secondFilter = new AgentListFilter(null, null, null, 3, cursor);

        // Act
        var (secondPage, totalCount) = await repository.ListAsync(secondFilter, CancellationToken.None);

        // Assert
        secondPage.Should().HaveCount(2);
        totalCount.Should().Be(5);
        secondPage.Should().BeInAscendingOrder(a => a.CreatedAtUtc);

        // The second page items should have CreatedAtUtc after the cursor
        foreach (var item in secondPage)
        {
            item.CreatedAtUtc.Should().BeAfter(lastItem.CreatedAtUtc);
        }
    }

    [Fact]
    public async Task ListAsync_Should_ReturnEmpty_When_CursorIsAfterLastItem()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var baseTime = new DateTime(2026, 6, 1, 0, 0, 0, DateTimeKind.Utc);
        var agent = TestEntityFactory.CreateAgentRegistration(createdAtUtc: baseTime);
        await repository.AddAsync(agent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Cursor positioned after the only item
        var futureCursor = $"{baseTime.AddDays(1):O}|{Guid.NewGuid()}";
        var cursor = Convert.ToBase64String(Encoding.UTF8.GetBytes(futureCursor));
        var filter = new AgentListFilter(null, null, null, 10, cursor);

        // Act
        var (items, _) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().BeEmpty();
    }

    [Fact]
    public async Task ListAsync_Should_FilterByStatus_When_StatusProvided()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var active = TestEntityFactory.CreateAgentRegistration(status: AgentStatus.Active);
        var draft = TestEntityFactory.CreateAgentRegistration(status: AgentStatus.Draft);
        var disabled = TestEntityFactory.CreateAgentRegistration(status: AgentStatus.Disabled);

        await repository.AddAsync(active, CancellationToken.None);
        await repository.AddAsync(draft, CancellationToken.None);
        await repository.AddAsync(disabled, CancellationToken.None);
        await context.SaveChangesAsync();

        var filter = new AgentListFilter("Active", null, null, 10, null);

        // Act
        var (items, totalCount) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().HaveCount(1);
        totalCount.Should().Be(1);
        items[0].Status.Should().Be(AgentStatus.Active);
    }

    [Fact]
    public async Task ListAsync_Should_FilterByEnvironment_When_EnvironmentProvided()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var devAgent = TestEntityFactory.CreateAgentRegistration(environment: AgentEnvironment.Development);
        var prodAgent = TestEntityFactory.CreateAgentRegistration(environment: AgentEnvironment.Production);

        await repository.AddAsync(devAgent, CancellationToken.None);
        await repository.AddAsync(prodAgent, CancellationToken.None);
        await context.SaveChangesAsync();

        var filter = new AgentListFilter(null, "Production", null, 10, null);

        // Act
        var (items, totalCount) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().HaveCount(1);
        totalCount.Should().Be(1);
        items[0].Environment.Should().Be(AgentEnvironment.Production);
    }

    [Fact]
    public async Task ListAsync_Should_FilterBySearch_When_SearchProvided()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var alpha = TestEntityFactory.CreateAgentRegistration(name: "Alpha Agent");
        var beta = TestEntityFactory.CreateAgentRegistration(name: "Beta Agent");
        var gamma = TestEntityFactory.CreateAgentRegistration(name: "Gamma Service");

        await repository.AddAsync(alpha, CancellationToken.None);
        await repository.AddAsync(beta, CancellationToken.None);
        await repository.AddAsync(gamma, CancellationToken.None);
        await context.SaveChangesAsync();

        var filter = new AgentListFilter(null, null, "Agent", 10, null);

        // Act
        var (items, totalCount) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().HaveCount(2);
        totalCount.Should().Be(2);
        items.Should().OnlyContain(a => a.Name.Contains("Agent"));
    }

    [Fact]
    public async Task ListAsync_Should_ExcludeSoftDeletedAgents_When_QueryFilterApplied()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var activeAgent = TestEntityFactory.CreateAgentRegistration(
            name: "Active Agent", isDeleted: false);
        var deletedAgent = TestEntityFactory.CreateAgentRegistration(
            name: "Deleted Agent", isDeleted: true);

        await repository.AddAsync(activeAgent, CancellationToken.None);
        await repository.AddAsync(deletedAgent, CancellationToken.None);
        await context.SaveChangesAsync();

        var filter = new AgentListFilter(null, null, null, 10, null);

        // Act
        var (items, totalCount) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().HaveCount(1);
        totalCount.Should().Be(1);
        items[0].Name.Should().Be("Active Agent");
    }

    [Fact]
    public async Task GetByIdAsync_Should_ExcludeSoftDeletedAgent_When_QueryFilterApplied()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);
        var deletedAgent = TestEntityFactory.CreateAgentRegistration(isDeleted: true);

        await repository.AddAsync(deletedAgent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await repository.GetByIdAsync(deletedAgent.Id, CancellationToken.None);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public async Task ListAsync_Should_CombineFilters_When_MultipleFiltersProvided()
    {
        // Arrange
        var dbName = Guid.NewGuid().ToString();
        await using var context = TestDbContextFactory.Create(dbName);
        var repository = new AgentRegistrationRepository(context);

        var match = TestEntityFactory.CreateAgentRegistration(
            name: "Prod Active Agent",
            environment: AgentEnvironment.Production,
            status: AgentStatus.Active);
        var wrongEnv = TestEntityFactory.CreateAgentRegistration(
            name: "Dev Active Agent",
            environment: AgentEnvironment.Development,
            status: AgentStatus.Active);
        var wrongStatus = TestEntityFactory.CreateAgentRegistration(
            name: "Prod Draft Agent",
            environment: AgentEnvironment.Production,
            status: AgentStatus.Draft);

        await repository.AddAsync(match, CancellationToken.None);
        await repository.AddAsync(wrongEnv, CancellationToken.None);
        await repository.AddAsync(wrongStatus, CancellationToken.None);
        await context.SaveChangesAsync();

        var filter = new AgentListFilter("Active", "Production", null, 10, null);

        // Act
        var (items, totalCount) = await repository.ListAsync(filter, CancellationToken.None);

        // Assert
        items.Should().HaveCount(1);
        totalCount.Should().Be(1);
        items[0].Id.Should().Be(match.Id);
    }

    [Fact]
    public async Task GetByIdAsync_Should_IncludeCredentialReference_When_Present()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new AgentRegistrationRepository(context);
        var agent = TestEntityFactory.CreateAgentRegistration();
        agent.CredentialReference = new AgentCredentialReference
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            CredentialType = CredentialType.Certificate,
            KeyVaultSecretUri = "https://vault.azure.net/secrets/test",
            CertificateThumbprint = "AABBCCDD",
            CreatedAtUtc = DateTime.UtcNow,
        };

        await repository.AddAsync(agent, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await repository.GetByIdAsync(agent.Id, CancellationToken.None);

        // Assert
        result.Should().NotBeNull();
        result!.CredentialReference.Should().NotBeNull();
        result.CredentialReference!.KeyVaultSecretUri.Should().Be("https://vault.azure.net/secrets/test");
    }
}
