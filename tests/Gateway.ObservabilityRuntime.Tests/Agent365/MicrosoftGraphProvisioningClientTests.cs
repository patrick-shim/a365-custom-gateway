using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.Agent365;

namespace Gateway.ObservabilityRuntime.Tests.Agent365;

public sealed class MicrosoftGraphProvisioningClientTests
{
    private const string GatewayBlueprintKey = "development-reusable-blueprint";
    private static readonly Guid OwnerObjectId =
        Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid ApplicationObjectId =
        Guid.Parse("33333333-3333-4333-8333-333333333333");
    private static readonly Guid BlueprintObjectId =
        Guid.Parse("55555555-5555-4555-8555-555555555555");
    private static readonly Guid BlueprintClientId =
        Guid.Parse("66666666-6666-4666-8666-666666666666");
    private static readonly Guid BlueprintPrincipalObjectId =
        Guid.Parse("77777777-7777-4777-8777-777777777777");
    private static readonly Guid AgentIdentityObjectId =
        Guid.Parse("88888888-8888-4888-8888-888888888888");
    private static readonly Guid ManagerApplicationId =
        Guid.Parse("99999999-9999-4999-8999-999999999999");

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_FollowsSafePagesAndReturnsQualifiedIds()
    {
        var firstObjectId = Guid.Parse("11111111-1111-4111-8111-111111111111");
        var firstClientId = Guid.Parse("22222222-2222-4222-8222-222222222222");
        var secondObjectId = Guid.Parse("33333333-3333-4333-8333-333333333333");
        var secondClientId = Guid.Parse("44444444-4444-4444-8444-444444444444");
        var nextLink =
            "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$skiptoken=next";
        var handler = new RecordingHttpMessageHandler((_, index) => index == 0
            ? JsonResponse(HttpStatusCode.OK, new Dictionary<string, object?>
            {
                ["value"] = new[]
                {
                    new
                    {
                        id = firstObjectId,
                        appId = firstClientId,
                        displayName = "Zulu",
                        managerApplications = new[] { ManagerApplicationId }
                    }
                },
                ["@odata.nextLink"] = nextLink
            })
            : JsonResponse(HttpStatusCode.OK, new
            {
                value = new[]
                {
                    new { id = secondObjectId, appId = secondClientId, displayName = "Alpha" }
                }
            }));
        var client = CreateClient(handler);

        var result = await client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        result.Select(item => item.DisplayName).Should().Equal("Alpha", "Zulu");
        result.Should().Contain(item =>
            item.BlueprintObjectId == firstObjectId &&
            item.BlueprintClientId == firstClientId &&
            item.IsAgent365Compatible &&
            item.Agent365CompatibilityIssue == null);
        result.Should().Contain(item =>
            item.BlueprintObjectId == secondObjectId &&
            item.BlueprintClientId == secondClientId &&
            !item.IsAgent365Compatible &&
            item.Agent365CompatibilityIssue ==
                Gateway.Domain.Models.AgentIdentityBlueprintCompatibilityIssues
                    .MissingRequiredManagerApplications);
        handler.Requests.Select(request => request.Uri).Should().Equal(
            "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,managerApplications&$top=100",
            nextLink);
        handler.Requests.Should().OnlyContain(request =>
            request.Authorization != null &&
            request.Authorization.Scheme == "Bearer" &&
            request.Authorization.Parameter == "opaque-provisioning-token");
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsHostileNextLinkBeforeDispatch()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new Dictionary<string, object?>
            {
                ["value"] = Array.Empty<object>(),
                ["@odata.nextLink"] = "https://attacker.example/collect"
            }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_NEXT_LINK_INVALID");
        handler.Requests.Should().ContainSingle();
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsSameHostWrongResourceNextLink()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new Dictionary<string, object?>
            {
                ["value"] = Array.Empty<object>(),
                ["@odata.nextLink"] =
                    "https://graph.microsoft.com/v1.0/applications?$skiptoken=wrong-resource"
            }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_NEXT_LINK_INVALID");
        handler.Requests.Should().ContainSingle();
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsRedirectResponseWithoutFollowingIt()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.Redirect);
            response.Headers.Location = new Uri("https://attacker.example/collect");
            return response;
        });
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_REQUEST_REJECTED");
        handler.Requests.Should().ContainSingle();
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsPagingCycleBeforeRedispatch()
    {
        const string firstPage =
            "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,managerApplications&$top=100";
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new Dictionary<string, object?>
            {
                ["value"] = Array.Empty<object>(),
                ["@odata.nextLink"] = firstPage
            }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_NEXT_LINK_INVALID");
        handler.Requests.Should().ContainSingle();
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsMissingCollectionValue()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new { }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_RESPONSE_INVALID");
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsDuplicateObjectIdentifiers()
    {
        var duplicateObjectId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new
            {
                value = new[]
                {
                    new { id = duplicateObjectId, appId = Guid.NewGuid(), displayName = "First" },
                    new { id = duplicateObjectId, appId = Guid.NewGuid(), displayName = "Second" }
                }
            }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_RESPONSE_INVALID");
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsDuplicateClientIdentifiers()
    {
        var duplicateClientId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new
            {
                value = new[]
                {
                    new { id = Guid.NewGuid(), appId = duplicateClientId, displayName = "First" },
                    new { id = Guid.NewGuid(), appId = duplicateClientId, displayName = "Second" }
                }
            }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_RESPONSE_INVALID");
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_AcceptsMatchingObjectAndClientIds()
    {
        var sharedId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new
            {
                value = new[]
                {
                    new
                    {
                        id = sharedId,
                        appId = sharedId,
                        displayName = "Reusable blueprint",
                        managerApplications = new[] { ManagerApplicationId }
                    }
                }
            }));
        var client = CreateClient(handler);

        var result = await client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        result.Should().ContainSingle().Which.Should().BeEquivalentTo(new
        {
            BlueprintObjectId = sharedId,
            BlueprintClientId = sharedId,
            DisplayName = "Reusable blueprint",
            IsAgent365Compatible = true,
            Agent365CompatibilityIssue = (string?)null
        });
    }

    [Fact]
    public async Task ListAgentIdentityBlueprintsAsync_MarksAllItemsUnavailableWhenManagerConfigurationIsMissing()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new
            {
                value = new[]
                {
                    new
                    {
                        id = BlueprintObjectId,
                        appId = BlueprintClientId,
                        displayName = "Reusable blueprint",
                        managerApplications = new[] { ManagerApplicationId }
                    }
                }
            }));
        var client = CreateClient(handler);

        var result = await client.ListAgentIdentityBlueprintsAsync(
            [],
            CancellationToken.None);

        var item = result.Should().ContainSingle().Subject;
        item.IsAgent365Compatible.Should().BeFalse();
        item.Agent365CompatibilityIssue.Should().Be(
            Gateway.Domain.Models.AgentIdentityBlueprintCompatibilityIssues
                .ManagerApplicationsNotConfigured);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task ListAgentIdentityBlueprintsAsync_RejectsEmptyIdentifiers(
        bool emptyObjectId,
        bool emptyClientId)
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new
            {
                value = new[]
                {
                    new
                    {
                        id = emptyObjectId ? Guid.Empty : Guid.NewGuid(),
                        appId = emptyClientId ? Guid.Empty : Guid.NewGuid(),
                        displayName = "Invalid blueprint"
                    }
                }
            }));
        var client = CreateClient(handler);

        var action = () => client.ListAgentIdentityBlueprintsAsync(
            [ManagerApplicationId],
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Gateway.Domain.Models.Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be("MICROSOFT_GRAPH_RESPONSE_INVALID");
    }

    [Fact]
    public async Task CreateBlueprintAsync_UsesExactV1TypedRouteAndDocumentedRelationships()
    {
        var handler = new RecordingHttpMessageHandler((_, _) => JsonResponse(
            HttpStatusCode.Created,
            new
            {
                id = BlueprintObjectId,
                appId = BlueprintClientId,
                displayName = "Blueprint"
            }));
        var client = CreateClient(handler);

        await client.CreateBlueprintAsync(
            "Blueprint",
            "Description",
            OwnerObjectId,
            [ManagerApplicationId],
            GatewayBlueprintKey,
            CancellationToken.None);

        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Post);
        request.Uri.Should().Be(
            "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint");
        request.Authorization.Should().Be(
            new AuthenticationHeaderValue("Bearer", "opaque-provisioning-token"));

        using var document = JsonDocument.Parse(request.Body!);
        var root = document.RootElement;
        root.GetProperty("displayName").GetString().Should().Be("Blueprint");
        root.GetProperty("sponsors@odata.bind")[0].GetString().Should().Be(
            $"https://graph.microsoft.com/v1.0/users/{OwnerObjectId:D}");
        root.GetProperty("owners@odata.bind")[0].GetString().Should().Be(
            $"https://graph.microsoft.com/v1.0/users/{OwnerObjectId:D}");
        root.GetProperty("managerApplications")[0].GetString().Should().Be(
            ManagerApplicationId.ToString("D"));
        root.GetProperty("tags").EnumerateArray().Select(value => value.GetString())
            .Should().Contain($"GatewayBlueprint:{GatewayBlueprintKey}");
    }

    [Fact]
    public async Task CreateBlueprintPrincipalAsync_UsesExactV1TypedRouteAndBlueprintClientId()
    {
        var handler = new RecordingHttpMessageHandler((_, _) => JsonResponse(
            HttpStatusCode.Created,
            new
            {
                id = BlueprintPrincipalObjectId,
                appId = BlueprintClientId
            }));
        var client = CreateClient(handler);

        await client.CreateServicePrincipalAsync(
            BlueprintClientId.ToString("D"),
            isBlueprintPrincipal: true,
            CancellationToken.None);

        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Post);
        request.Uri.Should().Be(
            "https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal");

        using var document = JsonDocument.Parse(request.Body!);
        document.RootElement.GetProperty("appId").GetString().Should().Be(
            BlueprintClientId.ToString("D"));
        request.Body.Should().NotContain(BlueprintObjectId.ToString("D"));
    }

    [Fact]
    public async Task GetBlueprintPrincipalAsync_UsesTypedRouteForObjectIdAndAppId()
    {
        var handler = new RecordingHttpMessageHandler((_, _) => JsonResponse(
            HttpStatusCode.OK,
            new
            {
                id = BlueprintPrincipalObjectId,
                appId = BlueprintClientId
            }));
        var client = CreateClient(handler);

        await client.GetBlueprintPrincipalAsync(
            BlueprintPrincipalObjectId.ToString("D"),
            CancellationToken.None);
        await client.GetBlueprintPrincipalByAppIdAsync(
            BlueprintClientId.ToString("D"),
            CancellationToken.None);

        handler.Requests.Select(request => request.Uri).Should().Equal(
            $"https://graph.microsoft.com/v1.0/servicePrincipals/{BlueprintPrincipalObjectId:D}/microsoft.graph.agentIdentityBlueprintPrincipal?$select=id,appId,displayName,appRoles",
            $"https://graph.microsoft.com/v1.0/servicePrincipals(appId='{BlueprintClientId:D}')/microsoft.graph.agentIdentityBlueprintPrincipal?$select=id,appId,displayName,appRoles");
    }

    [Fact]
    public async Task CreateAgentIdentityAsync_UsesExactV1TypedRouteAndBlueprintClientId()
    {
        var handler = new RecordingHttpMessageHandler((_, _) => JsonResponse(
            HttpStatusCode.Created,
            new
            {
                id = AgentIdentityObjectId,
                displayName = "Identity",
                agentIdentityBlueprintId = BlueprintClientId
            }));
        var client = CreateClient(handler);

        await client.CreateAgentIdentityAsync(
            "Identity",
            BlueprintClientId.ToString("D"),
            OwnerObjectId,
            CancellationToken.None);

        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Post);
        request.Uri.Should().Be(
            "https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentity");

        using var document = JsonDocument.Parse(request.Body!);
        var root = document.RootElement;
        root.GetProperty("agentIdentityBlueprintId").GetString().Should().Be(
            BlueprintClientId.ToString("D"));
        root.GetProperty("sponsors@odata.bind")[0].GetString().Should().Be(
            $"https://graph.microsoft.com/v1.0/users/{OwnerObjectId:D}");
        request.Body.Should().NotContain(BlueprintObjectId.ToString("D"));
    }

    [Fact]
    public async Task OrdinaryApplicationAndServicePrincipalReads_DoNotSelectDerivedProperties()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            JsonResponse(HttpStatusCode.OK, new { }));
        var client = CreateClient(handler);

        await client.GetApplicationAsync(
            ApplicationObjectId.ToString("D"),
            isBlueprint: false,
            includePasswordCredentials: false,
            CancellationToken.None);
        await client.GetServicePrincipalAsync(
            BlueprintPrincipalObjectId.ToString("D"),
            isAgentIdentity: false,
            CancellationToken.None);

        handler.Requests.Should().HaveCount(2);
        handler.Requests[0].Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/applications/{ApplicationObjectId:D}?$select=id,appId,displayName,tags");
        handler.Requests[0].Uri.Should().NotContain("managerApplications");
        handler.Requests[0].Uri.Should().NotContain("passwordCredentials");
        handler.Requests[1].Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/servicePrincipals/{BlueprintPrincipalObjectId:D}?$select=id,appId,displayName,appRoles");
        handler.Requests[1].Uri.Should().NotContain("agentIdentityBlueprintId");
    }

    [Fact]
    public async Task AgentIdRelationshipReads_UseDocumentedTypedRoutesAndExpand()
    {
        var handler = new RecordingHttpMessageHandler((request, _) =>
            request.Uri.Contains("servicePrincipals", StringComparison.Ordinal)
                ? JsonResponse(HttpStatusCode.OK, new
                {
                    id = AgentIdentityObjectId,
                    appId = AgentIdentityObjectId,
                    sponsors = new[] { new { id = OwnerObjectId } }
                })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    value = new[] { new { id = OwnerObjectId } }
                }));
        var client = CreateClient(handler);

        await client.ListBlueprintOwnerIdsAsync(BlueprintObjectId.ToString("D"), CancellationToken.None);
        await client.ListBlueprintSponsorIdsAsync(BlueprintObjectId.ToString("D"), CancellationToken.None);
        var identity = await client.GetServicePrincipalAsync(
            AgentIdentityObjectId.ToString("D"),
            isAgentIdentity: true,
            CancellationToken.None);

        handler.Requests.Select(request => request.Uri).Should().Equal(
            $"https://graph.microsoft.com/v1.0/applications/{BlueprintObjectId:D}/microsoft.graph.agentIdentityBlueprint/owners?$select=id&$top=999",
            $"https://graph.microsoft.com/v1.0/applications/{BlueprintObjectId:D}/microsoft.graph.agentIdentityBlueprint/sponsors?$select=id&$top=999",
            $"https://graph.microsoft.com/v1.0/servicePrincipals/{AgentIdentityObjectId:D}/microsoft.graph.agentIdentity?$select=id,appId,displayName,appRoles,agentIdentityBlueprintId&$expand=sponsors($select=id)");
        identity!.Sponsors.Should().ContainSingle(sponsor => sponsor.Id == OwnerObjectId.ToString());
    }

    private static MicrosoftGraphProvisioningClient CreateClient(
        RecordingHttpMessageHandler handler)
    {
        return new MicrosoftGraphProvisioningClient(
            new HttpClient(handler, disposeHandler: false)
            {
                BaseAddress = MicrosoftGraphProvisioningClient.OfficialBaseAddress
            },
            new RecordingTokenProvider());
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, object body)
    {
        return new HttpResponseMessage(status)
        {
            Content = JsonContent.Create(body)
        };
    }

    internal sealed record RecordedRequest(
        HttpMethod Method,
        string Uri,
        AuthenticationHeaderValue? Authorization,
        string? Body);

    internal sealed class RecordingHttpMessageHandler(
        Func<RecordedRequest, int, HttpResponseMessage> responseFactory) : HttpMessageHandler
    {
        public List<RecordedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var recorded = new RecordedRequest(
                request.Method,
                request.RequestUri!.AbsoluteUri,
                request.Headers.Authorization,
                request.Content is null
                    ? null
                    : await request.Content.ReadAsStringAsync(cancellationToken));
            Requests.Add(recorded);
            return responseFactory(recorded, Requests.Count - 1);
        }
    }

    internal sealed class RecordingTokenProvider : IAgent365ProvisioningTokenProvider
    {
        public int CallCount { get; private set; }

        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
        {
            CallCount++;
            return ValueTask.FromResult(new AccessToken(
                "opaque-provisioning-token",
                DateTimeOffset.UtcNow.AddMinutes(10)));
        }
    }
}
