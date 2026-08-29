using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class AgentIngressCredentialLifecycleTests : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    public AgentIngressCredentialLifecycleTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
        _client = factory.CreateAuthenticatedClient();
    }

    public void Dispose()
    {
        _client.Dispose();
        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task Rotation_ShouldIssueOverlapRevokeNamedKeyAndRejectLastUsableRevocation()
    {
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var registration = await RegisterAsync();
        var firstCredential = registration.GatewayCredential!;

        var issueResponse = await _client.PostAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials",
            content: null);

        issueResponse.StatusCode.Should().Be(HttpStatusCode.Created);
        issueResponse.Headers.CacheControl.Should().NotBeNull();
        issueResponse.Headers.CacheControl!.NoStore.Should().BeTrue();
        var issued = await issueResponse.Content
            .ReadFromJsonAsync<IssueAgentIngressCredentialResponse>(JsonOptions);
        issued.Should().NotBeNull();
        issued!.GatewayCredential.ApiKey.Should().StartWith("a365gw_v1_");
        issued.GatewayCredential.ApiKey.Should().NotBe(firstCredential.ApiKey);

        var listResponse = await _client.GetAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials");
        listResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var listJson = await listResponse.Content.ReadAsStringAsync();
        listJson.Should().NotContain(firstCredential.ApiKey);
        listJson.Should().NotContain(issued.GatewayCredential.ApiKey);
        listJson.ToLowerInvariant().Should().NotContain("secrethash");
        listJson.ToLowerInvariant().Should().NotContain("secretsalt");
        var credentials = JsonSerializer.Deserialize<AgentIngressCredentialListResponse>(
            listJson,
            JsonOptions);
        credentials!.Items.Should().HaveCount(2);

        var revokeResponse = await _client.DeleteAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials/{firstCredential.KeyId:D}");
        revokeResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var revoked = await revokeResponse.Content
            .ReadFromJsonAsync<RevokeAgentIngressCredentialResponse>(JsonOptions);
        revoked!.Credential.KeyId.Should().Be(firstCredential.KeyId);
        revoked.Credential.RevokedAtUtc.Should().NotBeNull();
        revoked.AlreadyRevoked.Should().BeFalse();

        var repeatedRevokeResponse = await _client.DeleteAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials/{firstCredential.KeyId:D}");
        repeatedRevokeResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var alreadyRevoked = await repeatedRevokeResponse.Content
            .ReadFromJsonAsync<RevokeAgentIngressCredentialResponse>(JsonOptions);
        alreadyRevoked!.Credential.KeyId.Should().Be(firstCredential.KeyId);
        alreadyRevoked.Credential.RevokedAtUtc.Should().Be(revoked.Credential.RevokedAtUtc);
        alreadyRevoked.AlreadyRevoked.Should().BeTrue();

        await SetAgentStatusAsync(registration.AgentId, AgentStatus.Active);
        _client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            firstCredential.ApiKey);
        (await _client.GetAsync("/api/v1/agent-runtime/readiness"))
            .StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        _client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            issued.GatewayCredential.ApiKey);
        (await _client.GetAsync("/api/v1/agent-runtime/readiness"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);

        HttpClientExtensions.SetRole("Gateway.Administrator");
        _client.DefaultRequestHeaders.Authorization = null;
        var lastCredentialResponse = await _client.DeleteAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials/{issued.GatewayCredential.KeyId:D}");
        lastCredentialResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var problem = JsonDocument.Parse(await lastCredentialResponse.Content.ReadAsStringAsync());
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be(ErrorCodes.AGENT_INGRESS_CREDENTIAL_LAST_USABLE);

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var auditEvents = await dbContext.AuditEvents
            .Where(item => item.AgentRegistrationId == registration.AgentId &&
                           (item.EventType == "GatewayCredentialIssued" ||
                            item.EventType == "GatewayCredentialRevoked"))
            .ToListAsync();
        auditEvents.Should().HaveCount(3);
        auditEvents.Should().OnlyContain(item =>
            item.Details != null &&
            !item.Details.Contains(firstCredential.ApiKey, StringComparison.Ordinal) &&
            !item.Details.Contains(issued.GatewayCredential.ApiKey, StringComparison.Ordinal));
    }

    [Fact]
    public async Task Revoke_ShouldEnforceCredentialBelongsToRouteAgent()
    {
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var first = await RegisterAsync();
        var second = await RegisterAsync();

        var response = await _client.DeleteAsync(
            $"/api/v1/agents/{second.AgentId:D}/credentials/{first.GatewayCredential!.KeyId:D}");

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
        var problem = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be(ErrorCodes.AGENT_INGRESS_CREDENTIAL_NOT_FOUND);

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var credential = await dbContext.AgentIngressCredentials
            .SingleAsync(item => item.Id == first.GatewayCredential.KeyId);
        credential.RevokedAtUtc.Should().BeNull();
    }

    [Theory]
    [InlineData("Gateway.Operator")]
    [InlineData("Gateway.Auditor")]
    [InlineData("Gateway.SupportReader")]
    public async Task CredentialLifecycleRoutes_ShouldRequireAdministrator(string role)
    {
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var registration = await RegisterAsync();
        HttpClientExtensions.SetRole(role);

        (await _client.GetAsync($"/api/v1/agents/{registration.AgentId:D}/credentials"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await _client.PostAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials",
            content: null)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await _client.DeleteAsync(
            $"/api/v1/agents/{registration.AgentId:D}/credentials/{registration.GatewayCredential!.KeyId:D}"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    private async Task<RegisterAgentResponse> RegisterAsync()
    {
        var response = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            new RegisterAgentRequest(
                $"credential-agent-{Guid.NewGuid():N}",
                "Credential lifecycle agent",
                null,
                "owner-object-id",
                "Development",
                null,
                TestRequestData.ValidBlueprint),
            JsonOptions);
        response.EnsureSuccessStatusCode();
        var registration = await response.Content
            .ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);
        registration.Should().NotBeNull();
        registration!.GatewayCredential.Should().NotBeNull();
        return registration;
    }

    private async Task SetAgentStatusAsync(Guid agentId, AgentStatus status)
    {
        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var agent = await dbContext.AgentRegistrations.SingleAsync(item => item.Id == agentId);
        agent.Status = status;
        await dbContext.SaveChangesAsync();
    }
}
