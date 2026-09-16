using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using Gateway.Agent365;
using Gateway.Contracts;
using Gateway.Domain.Models;
using Gateway.ObservabilityRuntime.Tests.Fixtures;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class DelegatedRegistryBaselineTests
{
    internal const string CreateUri = "https://graph.microsoft.com/beta/copilot/agentRegistrations";
    internal static string ReadUri => $"{CreateUri}/{FixtureIds.Registry:D}";
    internal static Agent365DelegatedRegistryRequest Request => new(
        FixtureIds.Agent, FixtureIds.Registry, "Offline registry agent", "Synthetic fixture",
        "offline-agent", FixtureIds.Actor, FixtureIds.Actor, FixtureIds.Principal,
        FixtureIds.Blueprint, new(FixtureIds.Timestamp), new(FixtureIds.Timestamp.AddMinutes(1)));

    [Fact]
    public async Task Lost_create_response_is_ambiguous_and_exact_id_readback_does_not_repeat_post()
    {
        using var transport = new ScriptedTransport();
        var tokens = new DelegatedTokenFixture();
        for (var call = 0; call < 3; call++)
            tokens.Calls.Expect(_ => FixtureIds.Token.Token);
        transport.Expect(HttpMethod.Post, CreateUri, request =>
        {
            Assert.Equal(FixtureIds.Registry.ToString("D"), request.Json.GetProperty("id").GetString());
            Assert.Equal(FixtureIds.Principal.ToString("D"), request.Json.GetProperty("agentIdentityId").GetString());
            Assert.Equal("Bearer", request.AuthorizationScheme);
            throw new HttpRequestException("Synthetic response loss after possible mutation.");
        });
        transport.Expect(HttpMethod.Get, ReadUri, HttpStatusCode.NotFound);
        transport.Expect(HttpMethod.Get, ReadUri, HttpStatusCode.OK, MatchingRecord().ToJsonString());
        using var http = transport.CreateClient(new Uri("https://graph.microsoft.com/"));
        var client = CreateClient(http, tokens);

        var failure = await Assert.ThrowsAsync<Agent365DelegatedRegistryException>(() =>
            client.CreateAsync(Request, CancellationToken.None));
        Assert.Equal(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT, failure.ErrorCode);
        Assert.True(failure.MutationMayHaveOccurred);
        Assert.True(failure.IsTransient);

        await client.VerifyAsync(Request.PlannedRegistrationId.ToString("D"), Request, CancellationToken.None);

        Assert.Single(transport.Requests, request => request.Method == HttpMethod.Post);
        Assert.Equal(2, transport.Requests.Count(request => request.Method == HttpMethod.Get));
        transport.AssertComplete();
        tokens.Calls.AssertComplete();
    }

    [Theory]
    [InlineData("id")]
    [InlineData("sourceAgentId")]
    [InlineData("agentIdentityId")]
    [InlineData("agentIdentityBlueprintId")]
    [InlineData("ownerIds")]
    [InlineData("createdBy")]
    public async Task Readback_requires_exact_registration_and_identity_binding(string changedField)
    {
        using var transport = new ScriptedTransport();
        var tokens = new DelegatedTokenFixture();
        tokens.Calls.Expect(_ => FixtureIds.Token.Token);
        var record = MatchingRecord();
        record[changedField] = changedField == "ownerIds"
            ? new JsonArray(FixtureIds.Registry.ToString("D"))
            : JsonValue.Create(FixtureIds.Tenant.ToString("D"));
        transport.Expect(HttpMethod.Get, ReadUri, HttpStatusCode.OK, record.ToJsonString());
        using var http = transport.CreateClient(new Uri("https://graph.microsoft.com/"));
        var client = CreateClient(http, tokens);

        var failure = await Assert.ThrowsAsync<Agent365DelegatedRegistryException>(() =>
            client.VerifyAsync(FixtureIds.Registry.ToString("D"), Request, CancellationToken.None));

        Assert.Equal(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT, failure.ErrorCode);
        Assert.False(failure.MutationMayHaveOccurred);
        Assert.False(failure.IsTransient);
        transport.AssertComplete();
        tokens.Calls.AssertComplete();
    }

    [Fact]
    public async Task Repeated_not_found_readback_stops_at_the_finite_verification_budget()
    {
        using var transport = new ScriptedTransport();
        var tokens = new DelegatedTokenFixture();
        for (var call = 0; call < 2; call++)
        {
            tokens.Calls.Expect(_ => FixtureIds.Token.Token);
            transport.Expect(HttpMethod.Get, ReadUri, HttpStatusCode.NotFound);
        }
        using var http = transport.CreateClient(new Uri("https://graph.microsoft.com/"));

        var failure = await Assert.ThrowsAsync<Agent365DelegatedRegistryException>(() =>
            CreateClient(http, tokens).VerifyAsync(FixtureIds.Registry.ToString("D"), Request, CancellationToken.None));

        Assert.Equal(ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE, failure.ErrorCode);
        Assert.True(failure.IsTransient);
        Assert.False(failure.MutationMayHaveOccurred);
        Assert.All(transport.Requests, request => Assert.Equal(HttpMethod.Get, request.Method));
        transport.AssertComplete();
        tokens.Calls.AssertComplete();
    }

    [Fact]
    public async Task Created_without_body_retains_the_durable_planned_identifier()
    {
        using var transport = new ScriptedTransport();
        var tokens = new DelegatedTokenFixture();
        tokens.Calls.Expect(_ => FixtureIds.Token.Token);
        transport.Expect(HttpMethod.Post, CreateUri, HttpStatusCode.Created, string.Empty);
        using var http = transport.CreateClient(new Uri("https://graph.microsoft.com/"));

        var id = await CreateClient(http, tokens).CreateAsync(Request, CancellationToken.None);

        Assert.Equal(FixtureIds.Registry.ToString("D"), id);
        transport.AssertComplete();
        tokens.Calls.AssertComplete();
    }

    [Fact]
    public async Task Missing_delegated_token_stops_before_mutation()
    {
        using var transport = new ScriptedTransport();
        var tokens = new DelegatedTokenFixture();
        tokens.Calls.Expect(_ => string.Empty);
        using var http = transport.CreateClient(new Uri("https://graph.microsoft.com/"));

        var failure = await Assert.ThrowsAsync<Agent365DelegatedRegistryException>(() =>
            CreateClient(http, tokens).CreateAsync(Request, CancellationToken.None));

        Assert.Equal(ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED, failure.ErrorCode);
        Assert.False(failure.MutationMayHaveOccurred);
        Assert.Empty(transport.Requests);
        transport.AssertComplete();
        tokens.Calls.AssertComplete();
    }

    internal static DelegatedAgent365RegistryClient CreateClient(HttpClient client, DelegatedTokenFixture tokens) =>
        new(client, tokens, "OfflineFixture", FixtureIds.Agent.ToString("D"), [TimeSpan.Zero, TimeSpan.Zero]);

    private static JsonObject MatchingRecord() => JsonSerializer.SerializeToNode(new
    {
        id = Request.PlannedRegistrationId.ToString("D"),
        sourceAgentId = Request.SourceAgentId,
        agentIdentityId = Request.AgentIdentityObjectId.ToString("D"),
        agentIdentityBlueprintId = Request.BlueprintClientId.ToString("D"),
        ownerIds = new[] { Request.OwnerObjectId.ToString("D") },
        createdBy = Request.CreatedByObjectId.ToString("D")
    })!.AsObject();
}
