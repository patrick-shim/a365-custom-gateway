using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Domain.Models;
using Gateway.EndToEndTests.Fixtures;
using NSubstitute;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class AgentIdentityBlueprintCatalogTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    public AgentIdentityBlueprintCatalogTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
        _client = factory.CreateAuthenticatedClient();
        _factory.MockBlueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([
                new AgentIdentityBlueprintCatalogItem(
                    Guid.Parse("11111111-1111-4111-8111-111111111111"),
                    Guid.Parse("22222222-2222-4222-8222-222222222222"),
                    "Reusable blueprint",
                    IsAgent365Compatible: true,
                    Agent365CompatibilityIssue: null)
            ]);
    }

    public void Dispose()
    {
        _client.Dispose();
        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task List_Should_ReturnOnlyQualifiedSafeFieldsForAdministrator()
    {
        var response = await _client.GetAsync("/api/v1/agent-identity-blueprints");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var item = document.RootElement.GetProperty("items").EnumerateArray().Single();
        item.EnumerateObject().Select(property => property.Name).Should().BeEquivalentTo(
            "blueprintObjectId",
            "blueprintClientId",
            "displayName",
            "isAgent365Compatible",
            "agent365CompatibilityIssue");
        item.GetProperty("blueprintObjectId").GetString().Should().Be(
            "11111111-1111-4111-8111-111111111111");
        item.GetProperty("blueprintClientId").GetString().Should().Be(
            "22222222-2222-4222-8222-222222222222");
        item.GetProperty("isAgent365Compatible").GetBoolean().Should().BeTrue();
        item.GetProperty("agent365CompatibilityIssue").ValueKind.Should().Be(
            JsonValueKind.Null);
    }

    [Fact]
    public async Task List_Should_PreserveEqualGraphIdAndAppIdValues()
    {
        var sharedIdentifier = Guid.Parse("33333333-3333-4333-8333-333333333333");
        _factory.MockBlueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([
                new AgentIdentityBlueprintCatalogItem(
                    sharedIdentifier,
                    sharedIdentifier,
                    "Equal-identifier blueprint",
                    IsAgent365Compatible: false,
                    Agent365CompatibilityIssue:
                        AgentIdentityBlueprintCompatibilityIssues.MissingRequiredManagerApplications)
            ]);

        var response = await _client.GetAsync("/api/v1/agent-identity-blueprints");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var item = document.RootElement.GetProperty("items").EnumerateArray().Single();
        item.GetProperty("blueprintObjectId").GetGuid().Should().Be(sharedIdentifier);
        item.GetProperty("blueprintClientId").GetGuid().Should().Be(sharedIdentifier);
        item.GetProperty("isAgent365Compatible").GetBoolean().Should().BeFalse();
        item.GetProperty("agent365CompatibilityIssue").GetString().Should().Be(
            AgentIdentityBlueprintCompatibilityIssues.MissingRequiredManagerApplications);
    }

    [Fact]
    public async Task Register_ShouldRejectIncompatibleExistingBlueprintBeforeAcceptance()
    {
        var selectedObjectId = Guid.Parse(TestRequestData.ValidBlueprint.BlueprintObjectId!);
        _factory.MockBlueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([
                new AgentIdentityBlueprintCatalogItem(
                    selectedObjectId,
                    selectedObjectId,
                    "Legacy blueprint",
                    IsAgent365Compatible: false,
                    Agent365CompatibilityIssue:
                        AgentIdentityBlueprintCompatibilityIssues.MissingRequiredManagerApplications)
            ]);
        var request = new RegisterAgentRequest(
            ExternalAgentId: $"incompatible-{Guid.NewGuid():N}",
            Name: "Incompatible blueprint test",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        var response = await _client.PostAsJsonAsync("/api/v1/agents", request);

        response.StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        document.RootElement.GetProperty("errorCode").GetString().Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE);
        response.Headers.Location.Should().BeNull();
    }

    [Fact]
    public async Task List_Should_Return401WhenUnauthenticated()
    {
        HttpClientExtensions.SetUnauthenticated();

        var response = await _client.GetAsync("/api/v1/agent-identity-blueprints");

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Theory]
    [InlineData("Gateway.Operator")]
    [InlineData("Gateway.Auditor")]
    [InlineData("Gateway.SupportReader")]
    [InlineData("ExternalAgent")]
    public async Task List_Should_Return403ForNonAdministratorRoles(string role)
    {
        HttpClientExtensions.SetRole(role);

        var response = await _client.GetAsync("/api/v1/agent-identity-blueprints");

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task List_Should_ReturnSafe503WhenGraphCatalogIsUnavailable()
    {
        _factory.MockBlueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns(_ => Task.FromException<IReadOnlyList<AgentIdentityBlueprintCatalogItem>>(
                new Agent365ProvisioningException(
                    "MICROSOFT_GRAPH_FORBIDDEN",
                    "Raw dependency detail must not escape.")));

        var response = await _client.GetAsync("/api/v1/agent-identity-blueprints");

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        response.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        var content = await response.Content.ReadAsStringAsync();
        using var document = JsonDocument.Parse(content);
        document.RootElement.GetProperty("errorCode").GetString().Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE);
        document.RootElement.TryGetProperty("correlationId", out _).Should().BeTrue();
        content.Should().NotContain("Raw dependency detail");
    }

    [Fact]
    public async Task List_Should_ReturnSafe502ForInvalidGraphCatalogResponse()
    {
        _factory.MockBlueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns(_ => Task.FromException<IReadOnlyList<AgentIdentityBlueprintCatalogItem>>(
                new Agent365ProvisioningException(
                    "MICROSOFT_GRAPH_RESPONSE_INVALID",
                    "Raw dependency detail must not escape.")));

        var response = await _client.GetAsync("/api/v1/agent-identity-blueprints");

        response.StatusCode.Should().Be(HttpStatusCode.BadGateway);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        document.RootElement.GetProperty("errorCode").GetString().Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE);
    }
}
