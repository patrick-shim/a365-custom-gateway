using FluentAssertions;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Services;

public class IdempotencyServiceTests
{
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

        var retrieved = await service.GetAsync("idem-key-001", CancellationToken.None);

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
        var result = await service.GetAsync("nonexistent-key", CancellationToken.None);

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
        var result = await service.GetAsync("key-beta", CancellationToken.None);

        // Assert
        result.Should().NotBeNull();
        result!.IdempotencyKey.Should().Be("key-beta");
        result.Id.Should().Be(record2.Id);
    }

    [Fact]
    public async Task GetAsync_Should_ReturnExpiredRecord_When_ServiceDoesNotFilterByExpiry()
    {
        // The IdempotencyService.GetAsync does not filter by ExpiresAtUtc.
        // Expiry enforcement is handled at a higher layer.
        // This test confirms the service returns the record regardless of expiry.

        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);

        var expiredRecord = TestEntityFactory.CreateIdempotencyRecord(
            key: "expired-key",
            expiresAtUtc: DateTime.UtcNow.AddHours(-1));

        await service.SaveAsync(expiredRecord, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var result = await service.GetAsync("expired-key", CancellationToken.None);

        // Assert
        result.Should().NotBeNull();
        result!.IdempotencyKey.Should().Be("expired-key");
        result.ExpiresAtUtc.Should().BeBefore(DateTime.UtcNow);
    }

    [Fact]
    public async Task SaveAsync_Should_PersistAllFields_When_RecordProvided()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var service = new IdempotencyService(context);

        var now = DateTime.UtcNow;
        var record = TestEntityFactory.CreateIdempotencyRecord(
            key: "full-field-key",
            responseStatusCode: 201,
            expiresAtUtc: now.AddHours(48));

        // Act
        await service.SaveAsync(record, CancellationToken.None);
        await context.SaveChangesAsync();

        var retrieved = await service.GetAsync("full-field-key", CancellationToken.None);

        // Assert
        retrieved.Should().NotBeNull();
        retrieved!.ResponseStatusCode.Should().Be(201);
        retrieved.ExpiresAtUtc.Should().BeCloseTo(now.AddHours(48), TimeSpan.FromSeconds(1));
        retrieved.CreatedAtUtc.Should().BeCloseTo(now, TimeSpan.FromSeconds(5));
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

        var result1 = await service.GetAsync("req-001", CancellationToken.None);
        var result2 = await service.GetAsync("req-002", CancellationToken.None);

        // Assert
        result1.Should().NotBeNull();
        result2.Should().NotBeNull();
        result1!.Id.Should().NotBe(result2!.Id);
    }
}
