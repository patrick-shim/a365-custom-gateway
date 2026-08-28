using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class IngressRateLimitingTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Fact]
    public async Task GatewayCredentialLimit_ShouldReturnSafe429ProblemDetails()
    {
        using var factory = new GatewayWebApplicationFactory();
        using var client = factory.CreateAuthenticatedClient();
        await SetLimitsAsync(factory, perCredential: 1, perRegistration: 100, global: 100);
        var registration = await RegisterAsync(client);

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            registration.GatewayCredential!.ApiKey);

        var accepted = await client.GetAsync("/api/v1/agent-runtime/readiness");
        var rejected = await client.GetAsync("/api/v1/agent-runtime/readiness");

        accepted.StatusCode.Should().Be(HttpStatusCode.NoContent);
        accepted.Headers.GetValues("X-RateLimit-Scope").Should().ContainSingle("credential");
        accepted.Headers.GetValues("X-RateLimit-Remaining").Should().ContainSingle("0");

        rejected.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        rejected.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        rejected.Headers.RetryAfter.Should().NotBeNull();
        rejected.Headers.GetValues("X-RateLimit-Scope").Should().ContainSingle("credential");

        var problem = JsonDocument.Parse(await rejected.Content.ReadAsStringAsync());
        problem.RootElement.GetProperty("errorCode").GetString().Should()
            .Be(ErrorCodes.RATE_LIMIT_EXCEEDED);
        problem.RootElement.GetProperty("status").GetInt32().Should().Be(429);
        problem.RootElement.GetRawText().Should()
            .NotContain(registration.GatewayCredential.ApiKey);
    }

    [Fact]
    public async Task RegistrationLimit_ShouldAggregateAcrossRotatedCredentials()
    {
        using var factory = new GatewayWebApplicationFactory();
        using var client = factory.CreateAuthenticatedClient();
        await SetLimitsAsync(factory, perCredential: 10, perRegistration: 1, global: 100);
        var registration = await RegisterAsync(client);

        var issueResponse = await client.PostAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials",
            content: null);
        issueResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        var rotated = await issueResponse.Content
            .ReadFromJsonAsync<IssueAgentIngressCredentialResponse>(JsonOptions);

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            registration.GatewayCredential!.ApiKey);
        (await client.GetAsync("/api/v1/agent-runtime/readiness"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            rotated!.GatewayCredential.ApiKey);
        var rejected = await client.GetAsync("/api/v1/agent-runtime/readiness");

        rejected.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        rejected.Headers.GetValues("X-RateLimit-Scope").Should()
            .ContainSingle("registration");
    }

    [Fact]
    public async Task GlobalLimit_ShouldAggregateAcrossRegistrations()
    {
        using var factory = new GatewayWebApplicationFactory();
        using var client = factory.CreateAuthenticatedClient();
        await SetLimitsAsync(factory, perCredential: 10, perRegistration: 10, global: 1);
        var first = await RegisterAsync(client);
        var second = await RegisterAsync(client);

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            first.GatewayCredential!.ApiKey);
        (await client.GetAsync("/api/v1/agent-runtime/readiness"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            second.GatewayCredential!.ApiKey);
        var rejected = await client.GetAsync("/api/v1/agent-runtime/readiness");

        rejected.StatusCode.Should().Be(HttpStatusCode.TooManyRequests);
        rejected.Headers.GetValues("X-RateLimit-Scope").Should().ContainSingle("global");
    }

    [Fact]
    public async Task ConcurrentRequests_ShouldAtomicallyAdmitOnlyConfiguredCount()
    {
        using var factory = new GatewayWebApplicationFactory();
        using var client = factory.CreateAuthenticatedClient();
        await SetLimitsAsync(factory, perCredential: 5, perRegistration: 100, global: 100);
        var registration = await RegisterAsync(client);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            registration.GatewayCredential!.ApiKey);

        var responses = await Task.WhenAll(
            Enumerable.Range(0, 20)
                .Select(_ => client.GetAsync("/api/v1/agent-runtime/readiness")));

        responses.Count(item => item.StatusCode == HttpStatusCode.NoContent)
            .Should().Be(5);
        responses.Count(item => item.StatusCode == HttpStatusCode.TooManyRequests)
            .Should().Be(15);

        foreach (var response in responses)
            response.Dispose();
    }

    private static async Task<RegisterAgentResponse> RegisterAsync(HttpClient client)
    {
        client.DefaultRequestHeaders.Authorization = null;
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: $"rate-limit-{Guid.NewGuid():N}",
            Name: "Rate limit test agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        var response = await client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);
        response.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var registered = await response.Content
            .ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);
        registered!.GatewayCredential.Should().NotBeNull();
        return registered;
    }

    private static async Task SetLimitsAsync(
        GatewayWebApplicationFactory factory,
        int perCredential,
        int perRegistration,
        int global)
    {
        await using var scope = factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        await dbContext.Database.EnsureCreatedAsync();
        var configuration = await dbContext.SystemConfigurations.SingleAsync();
        configuration.RateLimitPerClient = perCredential;
        configuration.RateLimitPerAgent = perRegistration;
        configuration.RateLimitGlobal = global;
        await dbContext.SaveChangesAsync();
    }
}
