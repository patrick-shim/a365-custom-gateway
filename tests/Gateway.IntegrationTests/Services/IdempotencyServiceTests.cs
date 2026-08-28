using FluentAssertions;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Services;

public class IdempotencyServiceTests
{
    [Fact]
    public async Task AcquireScopeAsync_ShouldSerializeSameScopeAndReleaseAfterCompletion()
    {
        var databaseName = Guid.NewGuid().ToString("N");
        await using var firstContext = TestDbContextFactory.Create(databaseName);
        await using var secondContext = TestDbContextFactory.Create(databaseName);
        var firstService = new IdempotencyService(firstContext);
        var secondService = new IdempotencyService(secondContext);
        var registrationId = Guid.NewGuid();
        const string endpoint = "/api/v1/ai-interactions";
        const string key = "scope-serialization";

        var firstLease = await firstService.AcquireScopeAsync(
            registrationId,
            endpoint,
            key,
            CancellationToken.None);
        var secondAcquire = secondService.AcquireScopeAsync(
            registrationId,
            endpoint,
            key,
            CancellationToken.None);

        (await Task.WhenAny(secondAcquire, Task.Delay(100)))
            .Should().NotBe(secondAcquire);

        await firstLease.CompleteAsync(CancellationToken.None);
        await firstLease.DisposeAsync();

        await using var secondLease = await secondAcquire.WaitAsync(
            TimeSpan.FromSeconds(2));
        await secondLease.CompleteAsync(CancellationToken.None);
    }

    [Fact]
    public async Task AcquireScopeAsync_ShouldReleaseCancelledWaiterWithoutPoisoningScope()
    {
        var databaseName = Guid.NewGuid().ToString("N");
        await using var firstContext = TestDbContextFactory.Create(databaseName);
        await using var secondContext = TestDbContextFactory.Create(databaseName);
        var firstService = new IdempotencyService(firstContext);
        var secondService = new IdempotencyService(secondContext);
        var registrationId = Guid.NewGuid();
        const string endpoint = "/api/v1/agent-activities";
        const string key = "scope-cancellation";

        var firstLease = await firstService.AcquireScopeAsync(
            registrationId,
            endpoint,
            key,
            CancellationToken.None);
        using var cancellation = new CancellationTokenSource(
            TimeSpan.FromMilliseconds(100));

        var cancelledAcquire = () => secondService.AcquireScopeAsync(
            registrationId,
            endpoint,
            key,
            cancellation.Token);

        await cancelledAcquire.Should().ThrowAsync<OperationCanceledException>();
        await firstLease.DisposeAsync();

        await using var replacementLease = await secondService.AcquireScopeAsync(
            registrationId,
            endpoint,
            key,
            CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2));
        await replacementLease.CompleteAsync(CancellationToken.None);
    }

    [Fact]
    public async Task AcquireScopeAsync_ShouldNotBlockDifferentRegistrationEndpointOrKey()
    {
        var databaseName = Guid.NewGuid().ToString("N");
        await using var firstContext = TestDbContextFactory.Create(databaseName);
        await using var secondContext = TestDbContextFactory.Create(databaseName);
        var firstService = new IdempotencyService(firstContext);
        var secondService = new IdempotencyService(secondContext);
        var firstRegistrationId = Guid.NewGuid();
        var secondRegistrationId = Guid.NewGuid();

        await using var heldLease = await firstService.AcquireScopeAsync(
            firstRegistrationId,
            "/api/v1/agent-activities",
            "shared-key",
            CancellationToken.None);

        await using var registrationLease = await secondService.AcquireScopeAsync(
            secondRegistrationId,
            "/api/v1/agent-activities",
            "shared-key",
            CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(1));
        await registrationLease.CompleteAsync(CancellationToken.None);

        await using var endpointLease = await secondService.AcquireScopeAsync(
            firstRegistrationId,
            "/api/v1/ai-interactions",
            "shared-key",
            CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(1));
        await endpointLease.CompleteAsync(CancellationToken.None);

        await using var keyLease = await secondService.AcquireScopeAsync(
            firstRegistrationId,
            "/api/v1/agent-activities",
            "different-key",
            CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(1));
        await keyLease.CompleteAsync(CancellationToken.None);
    }

    [Fact]
    public async Task SaveAsync_And_GetAsync_Should_ReturnRecord_When_RecordWasSaved()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);
        var record = TestEntityFactory.CreateIdempotencyRecord(key: "idem-key-001");

        // Act
        await service.SaveAsync(record, CancellationToken.None);
        await context.SaveChangesAsync();

        var retrieved = await service.GetAsync(
            record.AgentRegistrationId!.Value,
            record.Endpoint,
            "idem-key-001",
            DateTime.UtcNow,
            CancellationToken.None);

        // Assert
        retrieved.Should().NotBeNull();
        retrieved!.IdempotencyKey.Should().Be("idem-key-001");
        retrieved.ResponseStatusCode.Should().Be(record.ResponseStatusCode);
        retrieved.ResponseBody.Should().Be(record.ResponseBody);
        retrieved.RequestBodyHash.Should().Be(record.RequestBodyHash);
        retrieved.Endpoint.Should().Be(record.Endpoint);
    }

    [Fact]
    public async Task GetAsync_Should_ReturnNull_When_KeyDoesNotExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);

        // Act
        var result = await service.GetAsync(
            Guid.NewGuid(),
            "/api/v1/agent-activities",
            "nonexistent-key",
            DateTime.UtcNow,
            CancellationToken.None);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public async Task GetAsync_Should_ReturnRecord_When_MultipleRecordsExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);

        var record1 = TestEntityFactory.CreateIdempotencyRecord(key: "key-alpha");
        var record2 = TestEntityFactory.CreateIdempotencyRecord(key: "key-beta");
        var record3 = TestEntityFactory.CreateIdempotencyRecord(key: "key-gamma");

        await service.SaveAsync(record1, CancellationToken.None);
        await service.SaveAsync(record2, CancellationToken.None);
        await service.SaveAsync(record3, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await service.GetAsync(
            record2.AgentRegistrationId!.Value,
            record2.Endpoint,
            "key-beta",
            DateTime.UtcNow,
            CancellationToken.None);

        // Assert
        result.Should().NotBeNull();
        result!.IdempotencyKey.Should().Be("key-beta");
        result.Id.Should().Be(record2.Id);
    }

    [Fact]
    public async Task GetAsync_Should_ReturnNull_WhenScopedRecordExpired()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);

        var expiredRecord = TestEntityFactory.CreateIdempotencyRecord(
            key: "expired-key",
            expiresAtUtc: DateTime.UtcNow.AddHours(-1));

        context.IdempotencyRecords.Add(expiredRecord);
        await context.SaveChangesAsync();

        // Act
        var result = await service.GetAsync(
            expiredRecord.AgentRegistrationId!.Value,
            expiredRecord.Endpoint,
            "expired-key",
            DateTime.UtcNow,
            CancellationToken.None);

        // Assert
        result.Should().BeNull();
    }

    [Fact]
    public async Task SaveAsync_ShouldUseConfiguredRetentionForExpiration()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);
        var configuration = context.SystemConfigurations.Single();
        configuration.RetentionDaysIdempotencyRecords = 12;
        await context.SaveChangesAsync();

        var now = DateTime.UtcNow;
        var record = TestEntityFactory.CreateIdempotencyRecord(
            key: "full-field-key",
            responseStatusCode: 201);
        record.CreatedAtUtc = now;

        // Act
        await service.SaveAsync(record, CancellationToken.None);
        await context.SaveChangesAsync();

        var retrieved = await service.GetAsync(
            record.AgentRegistrationId!.Value,
            record.Endpoint,
            "full-field-key",
            DateTime.UtcNow,
            CancellationToken.None);

        // Assert
        retrieved.Should().NotBeNull();
        retrieved!.ResponseStatusCode.Should().Be(201);
        retrieved.ExpiresAtUtc.Should().Be(now.AddDays(12));
        retrieved.CreatedAtUtc.Should().Be(now);
    }

    [Fact]
    public async Task SaveAsync_ShouldUseSevenDayDefault_WhenConfigurationIsUnavailable()
    {
        await using var context = TestDbContextFactory.Create();
        context.SystemConfigurations.RemoveRange(context.SystemConfigurations);
        await context.SaveChangesAsync();
        var service = new IdempotencyService(context);
        var now = DateTime.UtcNow;
        var record = TestEntityFactory.CreateIdempotencyRecord(key: "default-ttl-key");
        record.CreatedAtUtc = now;

        await service.SaveAsync(record, CancellationToken.None);
        await context.SaveChangesAsync();

        record.ExpiresAtUtc.Should().Be(now.AddDays(7));
    }

    [Fact]
    public async Task GetAsync_ShouldFailClosedForUnexpiredLegacyUnownedRecord()
    {
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);
        var legacy = TestEntityFactory.CreateIdempotencyRecord(
            key: "legacy-key",
            endpoint: "/api/v1/agent-activities");
        legacy.AgentRegistrationId = null;
        context.IdempotencyRecords.Add(legacy);
        await context.SaveChangesAsync();

        var action = () => service.GetAsync(
            Guid.NewGuid(),
            legacy.Endpoint,
            legacy.IdempotencyKey,
            DateTime.UtcNow,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Application.Exceptions.ConflictException>();
        exception.Which.ErrorCode.Should().Be(Gateway.Contracts.ErrorCodes.IDEMPOTENCY_CONFLICT);
    }

    [Fact]
    public async Task SaveAsync_Should_PersistWithDifferentResponseBodies_When_MultipleRecordsSaved()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);

        var record1 = TestEntityFactory.CreateIdempotencyRecord(key: "req-001");
        var record2 = TestEntityFactory.CreateIdempotencyRecord(key: "req-002");

        // Act
        await service.SaveAsync(record1, CancellationToken.None);
        await service.SaveAsync(record2, CancellationToken.None);
        await context.SaveChangesAsync();

        var result1 = await service.GetAsync(
            record1.AgentRegistrationId!.Value,
            record1.Endpoint,
            "req-001",
            DateTime.UtcNow,
            CancellationToken.None);
        var result2 = await service.GetAsync(
            record2.AgentRegistrationId!.Value,
            record2.Endpoint,
            "req-002",
            DateTime.UtcNow,
            CancellationToken.None);

        // Assert
        result1.Should().NotBeNull();
        result2.Should().NotBeNull();
        result1!.Id.Should().NotBe(result2!.Id);
    }

    [Fact]
    public async Task SameKey_ShouldBeIsolatedByAgentAndEndpoint()
    {
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);
        var firstAgentId = Guid.NewGuid();
        var secondAgentId = Guid.NewGuid();
        var first = TestEntityFactory.CreateIdempotencyRecord(
            key: "shared-key",
            agentRegistrationId: firstAgentId,
            endpoint: "/api/v1/agent-activities");
        var second = TestEntityFactory.CreateIdempotencyRecord(
            key: "shared-key",
            agentRegistrationId: secondAgentId,
            endpoint: "/api/v1/agent-activities");
        var third = TestEntityFactory.CreateIdempotencyRecord(
            key: "shared-key",
            agentRegistrationId: firstAgentId,
            endpoint: "/api/v1/ai-interactions");
        await service.SaveAsync(first, CancellationToken.None);
        await service.SaveAsync(second, CancellationToken.None);
        await service.SaveAsync(third, CancellationToken.None);
        await context.SaveChangesAsync();

        var firstResult = await service.GetAsync(
            firstAgentId,
            first.Endpoint,
            "shared-key",
            DateTime.UtcNow,
            CancellationToken.None);
        var secondResult = await service.GetAsync(
            secondAgentId,
            second.Endpoint,
            "shared-key",
            DateTime.UtcNow,
            CancellationToken.None);
        var thirdResult = await service.GetAsync(
            firstAgentId,
            third.Endpoint,
            "shared-key",
            DateTime.UtcNow,
            CancellationToken.None);

        firstResult!.Id.Should().Be(first.Id);
        secondResult!.Id.Should().Be(second.Id);
        thirdResult!.Id.Should().Be(third.Id);
    }

    [Fact]
    public async Task SaveAsync_ShouldReplaceExpiredScopedRecordWithoutUniqueCollision()
    {
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);
        var now = DateTime.UtcNow;
        var expired = TestEntityFactory.CreateIdempotencyRecord(
            key: "reusable-key",
            expiresAtUtc: now.AddMinutes(-1));
        context.IdempotencyRecords.Add(expired);
        await context.SaveChangesAsync();

        (await service.GetAsync(
            expired.AgentRegistrationId!.Value,
            expired.Endpoint,
            expired.IdempotencyKey,
            now,
            CancellationToken.None)).Should().BeNull();

        var replacement = TestEntityFactory.CreateIdempotencyRecord(
            key: expired.IdempotencyKey,
            expiresAtUtc: now.AddHours(24),
            agentRegistrationId: expired.AgentRegistrationId!.Value,
            endpoint: expired.Endpoint);
        replacement.RequestBodyHash = "replacement-hash";
        replacement.ResponseBody = """{"status":"replacement"}""";
        replacement.CreatedAtUtc = now;
        await service.SaveAsync(replacement, CancellationToken.None);
        await context.SaveChangesAsync();

        context.IdempotencyRecords.Should().ContainSingle();
        var persisted = context.IdempotencyRecords.Single();
        persisted.Id.Should().Be(expired.Id);
        persisted.RequestBodyHash.Should().Be("replacement-hash");
        persisted.ResponseBody.Should().Be("""{"status":"replacement"}""");
        persisted.ExpiresAtUtc.Should().BeAfter(now);
    }
}
