using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.Agent365;

namespace Gateway.ObservabilityRuntime.Tests.Agent365;

public sealed class DefaultAzureObservabilityTokenProviderTests
{
    private static readonly Guid TenantId = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid AgentIdentityClientId = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid BlueprintClientId = Guid.Parse("33333333-3333-4333-8333-333333333333");
    private static readonly Guid ManagedIdentityClientId = Guid.Parse("44444444-4444-4444-8444-444444444444");
    private static readonly Guid ManagedIdentityPrincipalId = Guid.Parse("55555555-5555-4555-8555-555555555555");

    [Fact]
    public async Task GetTokenAsync_UsesTwoStageAgentIdentityFlowAndCachesFinalToken()
    {
        var managedIdentityAssertion = CreateManagedIdentityAssertion();
        var agentIdentityToken = CreateAgentIdentityToken();
        var credential = new StubTokenCredential(managedIdentityAssertion);
        var handler = new RecordingSequenceHandler(
            _ => TokenResponse("blueprint-t1"),
            _ => TokenResponse(agentIdentityToken));
        var provider = CreateProvider(credential, handler);

        var first = await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);
        var second = await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        first.Token.Should().Be(agentIdentityToken);
        second.Token.Should().Be(agentIdentityToken);
        credential.CallCount.Should().Be(1);
        credential.RequestedScopes.Should().Equal(
            DefaultAzureObservabilityTokenProvider.TokenExchangeScope);
        handler.Requests.Should().HaveCount(2);

        var expectedEndpoint =
            $"https://login.microsoftonline.com/{TenantId:D}/oauth2/v2.0/token";
        handler.Requests.Should().OnlyContain(request => request.Uri == expectedEndpoint);

        handler.Requests[0].Form.Should().BeEquivalentTo(new Dictionary<string, string>
        {
            ["client_id"] = BlueprintClientId.ToString("D"),
            ["scope"] = DefaultAzureObservabilityTokenProvider.TokenExchangeScope,
            ["fmi_path"] = AgentIdentityClientId.ToString("D"),
            ["client_assertion_type"] =
                "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            ["client_assertion"] = managedIdentityAssertion.Token,
            ["grant_type"] = "client_credentials"
        });
        handler.Requests[1].Form.Should().BeEquivalentTo(new Dictionary<string, string>
        {
            ["client_id"] = AgentIdentityClientId.ToString("D"),
            ["scope"] = DefaultAzureObservabilityTokenProvider.ObservabilityScope,
            ["client_assertion_type"] =
                "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            ["client_assertion"] = "blueprint-t1",
            ["grant_type"] = "client_credentials"
        });
        handler.Requests[1].Form.Should().NotContainKey("fmi_path");
    }

    [Fact]
    public async Task GetTokenAsync_ManagedIdentityPrincipalDoesNotMatch_FailsBeforeExchange()
    {
        var assertion = CreateManagedIdentityAssertion(
            principalId: Guid.Parse("99999999-9999-4999-8999-999999999999"));
        var credential = new StubTokenCredential(assertion);
        var handler = new RecordingSequenceHandler(_ => TokenResponse("unused"));
        var provider = CreateProvider(credential, handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("ManagedIdentityPrincipalMismatch");
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task GetTokenAsync_FinalTokenBelongsToAnotherAgent_FailsClosed()
    {
        var wrongAgentToken = CreateAgentIdentityToken(
            agentIdentityClientId: Guid.Parse("99999999-9999-4999-8999-999999999999"));
        var handler = new RecordingSequenceHandler(
            _ => TokenResponse("blueprint-t1"),
            _ => TokenResponse(wrongAgentToken));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("AgentIdentityMismatch");
    }

    [Fact]
    public async Task GetTokenAsync_DelegatedFinalToken_FailsClosed()
    {
        var delegatedToken = CreateAgentIdentityToken(scope: "observability.write");
        var handler = new RecordingSequenceHandler(
            _ => TokenResponse("blueprint-t1"),
            _ => TokenResponse(delegatedToken));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("DelegatedTokenNotAllowed");
    }

    [Fact]
    public async Task GetTokenAsync_BlueprintExchangeThrottled_ThrowsRetryableException()
    {
        var handler = new RecordingSequenceHandler(
            _ => new HttpResponseMessage(HttpStatusCode.TooManyRequests));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityTransientException>();
        exception.Which.Code.Should().Be("BlueprintTokenHttp429");
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    public async Task GetTokenAsync_BlueprintFederatedCredentialPropagation_ThrowsRetryableException(
        HttpStatusCode statusCode)
    {
        var handler = new RecordingSequenceHandler(
            _ => OAuthErrorResponse(
                statusCode,
                "invalid_client",
                [70021],
                "A response detail that must not be parsed or persisted."));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityTransientException>();
        exception.Which.Code.Should().Be("BlueprintTokenFederatedCredentialPropagation");
        handler.Requests.Should().ContainSingle();
    }

    [Fact]
    public async Task GetTokenAsync_PropagationTextWithoutErrorCode_RemainsTerminal()
    {
        var handler = new RecordingSequenceHandler(
            _ => OAuthErrorResponse(
                HttpStatusCode.BadRequest,
                "invalid_client",
                [70025],
                "AADSTS70021 text alone must not control retry classification."));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("BlueprintTokenHttp400");
    }

    [Fact]
    public async Task GetTokenAsync_AgentExchangeRejected_ThrowsTerminalConfigurationException()
    {
        var handler = new RecordingSequenceHandler(
            _ => TokenResponse("blueprint-t1"),
            _ => new HttpResponseMessage(HttpStatusCode.BadRequest));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("AgentIdentityTokenHttp400");
    }

    [Fact]
    public async Task GetTokenAsync_SystemAssignedIdentityWithoutConfiguredIds_UsesAssertionObjectId()
    {
        var agentIdentityToken = CreateAgentIdentityToken();
        var handler = new RecordingSequenceHandler(
            _ => TokenResponse("blueprint-t1"),
            _ => TokenResponse(agentIdentityToken));
        var provider = new DefaultAzureObservabilityTokenProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion()),
            new StubHttpClientFactory(handler),
            managedIdentityPrincipalId: null,
            managedIdentityClientId: null);

        var result = await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        result.Token.Should().Be(agentIdentityToken);
    }

    [Fact]
    public async Task GetTokenAsync_ManagedIdentityV2ResourceAudience_IsAccepted()
    {
        var agentIdentityToken = CreateAgentIdentityToken();
        var handler = new RecordingSequenceHandler(
            _ => TokenResponse("blueprint-t1"),
            _ => TokenResponse(agentIdentityToken));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion(
                audience: DefaultAzureObservabilityTokenProvider.TokenExchangeResourceId)),
            handler);

        var result = await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        result.Token.Should().Be(agentIdentityToken);
        handler.Requests.Should().HaveCount(2);
    }

    [Fact]
    public async Task GetTokenAsync_UnknownManagedIdentityAudience_FailsBeforeExchange()
    {
        var handler = new RecordingSequenceHandler(_ => TokenResponse("unused"));
        var provider = CreateProvider(
            new StubTokenCredential(CreateManagedIdentityAssertion(audience: "api://unexpected")),
            handler);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("ManagedIdentityAssertionInvalidAudience");
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task GetTokenAsync_ManagedIdentityAssertionMissingObjectId_FailsBeforeExchange()
    {
        var assertion = new AccessToken(
            CreateJwt(new
            {
                aud = DefaultAzureObservabilityTokenProvider.TokenExchangeAudience,
                appid = ManagedIdentityClientId,
                tid = TenantId,
                exp = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()
            }),
            DateTimeOffset.UtcNow.AddHours(1));
        var handler = new RecordingSequenceHandler(_ => TokenResponse("unused"));
        var provider = new DefaultAzureObservabilityTokenProvider(
            new StubTokenCredential(assertion),
            new StubHttpClientFactory(handler),
            managedIdentityPrincipalId: null,
            managedIdentityClientId: null);

        var action = async () => await provider.GetTokenAsync(
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"),
            TenantId.ToString("D"),
            CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("MissingManagedIdentityPrincipal");
        handler.Requests.Should().BeEmpty();
    }

    private static DefaultAzureObservabilityTokenProvider CreateProvider(
        TokenCredential credential,
        HttpMessageHandler handler)
    {
        return new DefaultAzureObservabilityTokenProvider(
            credential,
            new StubHttpClientFactory(handler),
            ManagedIdentityPrincipalId.ToString("D"),
            ManagedIdentityClientId.ToString("D"));
    }

    private static AccessToken CreateManagedIdentityAssertion(
        Guid? principalId = null,
        string? audience = null)
    {
        var token = CreateJwt(new
        {
            aud = audience ?? DefaultAzureObservabilityTokenProvider.TokenExchangeAudience,
            appid = ManagedIdentityClientId,
            oid = principalId ?? ManagedIdentityPrincipalId,
            tid = TenantId,
            exp = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()
        });
        return new AccessToken(token, DateTimeOffset.UtcNow.AddHours(1));
    }

    private static string CreateAgentIdentityToken(
        Guid? agentIdentityClientId = null,
        string? scope = null,
        string? audience = null,
        string[]? roles = null)
    {
        return CreateJwt(new
        {
            aud = audience ?? DefaultAzureObservabilityTokenProvider.ObservabilityAudience,
            appid = agentIdentityClientId ?? AgentIdentityClientId,
            tid = TenantId,
            roles = roles ?? [DefaultAzureObservabilityTokenProvider.ObservabilityRole],
            scp = scope,
            exp = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()
        });
    }

    private static string CreateJwt<TPayload>(TPayload payload)
    {
        var header = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(new { alg = "none" }));
        var body = Base64UrlEncode(JsonSerializer.SerializeToUtf8Bytes(payload));
        return $"{header}.{body}.unsigned";
    }

    private static string Base64UrlEncode(byte[] value)
    {
        return Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static HttpResponseMessage TokenResponse(string accessToken)
    {
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                token_type = "Bearer",
                access_token = accessToken,
                expires_in = 3600
            })
        };
    }

    private static HttpResponseMessage OAuthErrorResponse(
        HttpStatusCode statusCode,
        string error,
        long[] errorCodes,
        string errorDescription)
    {
        return new HttpResponseMessage(statusCode)
        {
            Content = JsonContent.Create(new
            {
                error,
                error_description = errorDescription,
                error_codes = errorCodes
            })
        };
    }

    private sealed class StubTokenCredential(AccessToken accessToken) : TokenCredential
    {
        public int CallCount { get; private set; }
        public string[] RequestedScopes { get; private set; } = [];

        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            Record(requestContext);
            return accessToken;
        }

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            Record(requestContext);
            return ValueTask.FromResult(accessToken);
        }

        private void Record(TokenRequestContext requestContext)
        {
            CallCount++;
            RequestedScopes = requestContext.Scopes;
        }
    }

    private sealed class StubHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private sealed class RecordingSequenceHandler(
        params Func<HttpRequestMessage, HttpResponseMessage>[] responses) : HttpMessageHandler
    {
        private int _responseIndex;

        public List<RecordedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var encodedForm = request.Content is null
                ? string.Empty
                : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add(new RecordedRequest(
                request.RequestUri?.AbsoluteUri,
                ParseForm(encodedForm)));

            if (_responseIndex >= responses.Length)
                throw new InvalidOperationException("No response was configured for this request.");

            return responses[_responseIndex++](request);
        }

        private static Dictionary<string, string> ParseForm(string encodedForm)
        {
            return encodedForm.Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Select(part => part.Split('=', 2))
                .ToDictionary(
                    part => DecodeFormValue(part[0]),
                    part => DecodeFormValue(part.Length == 2 ? part[1] : string.Empty),
                    StringComparer.Ordinal);
        }

        private static string DecodeFormValue(string value)
        {
            return Uri.UnescapeDataString(value.Replace('+', ' '));
        }
    }

    private sealed record RecordedRequest(string? Uri, Dictionary<string, string> Form);
}
