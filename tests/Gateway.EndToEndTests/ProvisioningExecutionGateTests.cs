using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using FluentAssertions;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class ProvisioningExecutionGateTests : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly GatewayWebApplicationFactory _factory;

    public ProvisioningExecutionGateTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
    }

    public void Dispose() => TestAuthHandler.Reset();

    [Fact]
    public async Task Registration_WhenExecutionDisabled_ReturnsSafe503WithoutPersistingWork()
    {
        using var disabledFactory = CreateFactory(
            executionEnabled: false,
            allowContinuousDevelopmentAccess: true);
        using var client = disabledFactory.CreateClient();
        TestAuthHandler.Reset();
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var before = await ReadWorkCountsAsync(disabledFactory.Services);
        var request = new RegisterAgentRequest(
            ExternalAgentId: $"gate-test-{Guid.NewGuid():N}",
            Name: "Disabled provisioning gate test",
            Description: null,
            OwnerObjectId: "02ed1e89-4ad1-4073-8e90-4aa865784896",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        var response = await client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        response.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("title").GetString().Should().Be("Provisioning Unavailable");
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        problem.GetProperty("detail").GetString().Should().Contain("admission gate is closed");
        problem.GetProperty("correlationId").GetString().Should().NotBeNullOrWhiteSpace();

        var after = await ReadWorkCountsAsync(disabledFactory.Services);
        after.Should().Be(before);
    }

    [Fact]
    public async Task Registration_WhenContinuousDevelopmentAccessIsDisabled_Returns503WithoutPersistingWork()
    {
        using var closedFactory = CreateFactory(
            executionEnabled: true,
            allowContinuousDevelopmentAccess: false);
        using var client = closedFactory.CreateClient();
        TestAuthHandler.Reset();
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var before = await ReadWorkCountsAsync(closedFactory.Services);
        var request = new RegisterAgentRequest(
            ExternalAgentId: $"gate-test-{Guid.NewGuid():N}",
            Name: "Closed provisioning admission test",
            Description: null,
            OwnerObjectId: "02ed1e89-4ad1-4073-8e90-4aa865784896",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        var response = await client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        var after = await ReadWorkCountsAsync(closedFactory.Services);
        after.Should().Be(before);
    }

    [Fact]
    public async Task RetryProvisioning_WhenExecutionDisabled_Returns503WithoutCreatingJob()
    {
        using var disabledFactory = CreateFactory(
            executionEnabled: false,
            allowContinuousDevelopmentAccess: true);
        using var client = disabledFactory.CreateClient();
        TestAuthHandler.Reset();
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var before = await ReadWorkCountsAsync(disabledFactory.Services);

        var response = await client.PostAsync(
            $"/api/v1/agents/{Guid.NewGuid():D}:retry-provisioning",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        var after = await ReadWorkCountsAsync(disabledFactory.Services);
        after.Should().Be(before);
    }

    [Fact]
    public async Task RetryProvisioning_WhenContinuousDevelopmentAccessIsDisabled_Returns503WithoutCreatingJob()
    {
        using var closedFactory = CreateFactory(
            executionEnabled: true,
            allowContinuousDevelopmentAccess: false);
        using var client = closedFactory.CreateClient();
        TestAuthHandler.Reset();
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var before = await ReadWorkCountsAsync(closedFactory.Services);

        var response = await client.PostAsync(
            $"/api/v1/agents/{Guid.NewGuid():D}:retry-provisioning",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        (await ReadWorkCountsAsync(closedFactory.Services)).Should().Be(before);
    }

    [Fact]
    public async Task SystemConfig_ReportsTheDeploymentExecutionGate()
    {
        using var disabledFactory = CreateFactory(
            executionEnabled: true,
            allowContinuousDevelopmentAccess: false);
        using var client = disabledFactory.CreateClient();
        TestAuthHandler.Reset();
        HttpClientExtensions.SetRole("Gateway.Administrator");
        await EnsureSystemConfigExistsAsync(disabledFactory.Services);

        var response = await client.GetAsync("/api/v1/system/config");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var config = await response.Content.ReadFromJsonAsync<SystemConfigDto>(JsonOptions);
        config.Should().NotBeNull();
        config!.ProvisioningExecutionEnabled.Should().BeFalse();
    }

    private WebApplicationFactory<Program> CreateFactory(
        bool executionEnabled,
        bool allowContinuousDevelopmentAccess) =>
        _factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, configuration) =>
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["Provisioning:ExecutionEnabled"] = executionEnabled.ToString(),
                    ["Provisioning:AllowContinuousDevelopmentAccess"] =
                        allowContinuousDevelopmentAccess.ToString()
                })));

    private static async Task<WorkCounts> ReadWorkCountsAsync(IServiceProvider services)
    {
        await using var scope = services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        return new WorkCounts(
            await dbContext.AgentRegistrations.CountAsync(),
            await dbContext.ProvisioningJobs.CountAsync(),
            await dbContext.OutboxMessages.CountAsync());
    }

    private static async Task EnsureSystemConfigExistsAsync(IServiceProvider services)
    {
        await using var scope = services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        if (await dbContext.SystemConfigurations.AnyAsync())
        {
            return;
        }

        dbContext.SystemConfigurations.Add(new SystemConfiguration
        {
            Id = new Guid("7c9e6679-7425-40de-944b-e07fc1f90ae7"),
            ProvisioningMode = "Automatic",
            DefaultObservabilityMode = "Agent365",
            DefaultPurviewEnabled = false,
            RetentionDaysActivityReceipts = 90,
            RetentionDaysAuditEvents = 365,
            RetentionDaysIdempotencyRecords = 7,
            RetentionDaysOutboxMessages = 30,
            RateLimitPerClient = 100,
            RateLimitPerAgent = 1_000,
            RateLimitGlobal = 10_000,
            ReconciliationEnabled = true,
            ReconciliationIntervalHours = 24,
            StuckTransitionTimeoutDays = 7,
            UpdatedAtUtc = DateTime.UtcNow
        });
        await dbContext.SaveChangesAsync();
    }

    private sealed record WorkCounts(int Agents, int Jobs, int OutboxMessages);
}
