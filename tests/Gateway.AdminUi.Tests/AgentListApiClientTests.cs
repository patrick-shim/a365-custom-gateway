using System.Net;
using System.Net.Http.Json;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Logging.Abstractions;

namespace Gateway.AdminUi.Tests;

public sealed class AgentListApiClientTests
{
    [Fact]
    public async Task Client_round_trips_the_exact_opaque_cursor_and_combined_literal_filters()
    {
        using var terminal = new ListingTransport();
        using var http = new HttpClient(terminal) { BaseAddress = new Uri("https://listing.example.invalid/") };
        var tokens = new ListingTokens();
        var client = new GatewayApiClient(http, tokens, NullLogger<GatewayApiClient>.Instance);
        var query = new AgentListQuery("Active", "Production", "invoice-eu %_[", 100);

        var first = await client.GetAgentsAsync(query);
        var second = await client.GetAgentsAsync(query with { Cursor = first.NextCursor });

        Assert.Equal(ListingTransport.Cursor, first.NextCursor);
        Assert.Null(second.NextCursor);
        Assert.Equal(137, first.TotalCount);
        Assert.Equal(137, second.TotalCount);
        Assert.Equal(2, terminal.Calls);
        Assert.Equal(2, tokens.Calls);
    }

    private sealed class ListingTransport : HttpMessageHandler
    {
        public const string Cursor = "opaque+/cursor==";
        public int Calls { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.True(Calls < 2, "Unscripted listing HTTP call; this terminal fixture has no network fallback.");
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal("listing.example.invalid", request.RequestUri!.Host);
            Assert.Equal("/api/v1/agents", request.RequestUri.AbsolutePath);
            var query = QueryHelpers.ParseQuery(request.RequestUri.Query);
            Assert.Equal("Active", query["status"]);
            Assert.Equal("Production", query["environment"]);
            Assert.Equal("invoice-eu %_[", query["search"]);
            Assert.Equal("100", query["limit"]);
            if (Calls == 0)
                Assert.False(query.ContainsKey("cursor"));
            else
                Assert.Equal(Cursor, query["cursor"]);
            Calls++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new AgentListResponse([], Calls == 1 ? Cursor : null, 137))
            });
        }
    }

    private sealed class ListingTokens : IGatewayAccessTokenProvider
    {
        public int Calls { get; private set; }
        public Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
        {
            Assert.True(Calls++ < 2, "Unscripted token request; no ambient authentication exists in this fixture.");
            return Task.FromResult("synthetic-listing-token-not-a-credential");
        }
    }
}
