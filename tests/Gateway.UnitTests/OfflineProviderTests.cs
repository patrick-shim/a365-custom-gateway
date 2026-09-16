using System.Net;
using System.Text;
using Azure.Core;
using Gateway.ContentSafety;
using Gateway.Domain.Models;
using Gateway.TestSupport;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests;

public sealed class OfflineProviderTests
{
    [Fact]
    public async Task Every_unscripted_provider_boundary_denies_calls_without_a_real_transport()
    {
        await Assert.ThrowsAsync<OfflineProviderException>(() => new OfflineBlueprintCatalog().ListAsync(default));
        await Assert.ThrowsAsync<OfflineProviderException>(() => new OfflinePromptShield()
            .EvaluateAsync("synthetic", Subject(), default));
        await Assert.ThrowsAsync<OfflineProviderException>(() => new OfflinePurview().EvaluatePromptAsync(null!, default));
        await Assert.ThrowsAsync<OfflineProviderException>(() => new OfflinePurview().EvaluateInteractionAsync(null!, default));
        await Assert.ThrowsAsync<OfflineProviderException>(() => new OfflineContentStore()
            .StoreAsync(Guid.NewGuid(), Guid.NewGuid(), "p", "text/plain", "r", "text/plain", default));
        using var http = new HttpClient(new OfflineHttpHandler());
        await Assert.ThrowsAsync<OfflineProviderException>(() => http.GetAsync("https://offline.invalid/"));
    }

    [Fact]
    public async Task Scripted_provider_transports_and_credentials_reject_calls_beyond_the_finite_budget()
    {
        var catalog = new OfflineBlueprintCatalog { Items = [] };
        await catalog.ListAsync(default);
        await Assert.ThrowsAsync<OfflineProviderException>(() => catalog.ListAsync(default));

        var shield = new OfflinePromptShield
        {
            IsEnabled = true,
            Evaluate = (_, _, _) => Task.FromResult(new PromptShieldEvaluationResult(false))
        };
        await shield.EvaluateAsync("synthetic", Subject(), default);
        await Assert.ThrowsAsync<OfflineProviderException>(() => shield.EvaluateAsync("synthetic", Subject(), default));
        Assert.Single(shield.Subjects);

        var store = new OfflineContentStore { AllowStaging = true };
        await store.StoreAsync(Guid.NewGuid(), Guid.NewGuid(), "p", "text/plain", "r", "text/plain", default);
        await Assert.ThrowsAsync<OfflineProviderException>(() =>
            store.StoreAsync(Guid.NewGuid(), Guid.NewGuid(), "p", "text/plain", "r", "text/plain", default));
        Assert.Single(store.Staged);

        using var http = new HttpClient(new OfflineHttpHandler
        {
            Respond = (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK))
        });
        using var response = await http.GetAsync("https://offline.invalid/");
        await Assert.ThrowsAsync<OfflineProviderException>(() => http.GetAsync("https://offline.invalid/"));

        var tokens = new ScriptedTokenProvider { Token = SyntheticToken() };
        await tokens.GetTokenAsync(default);
        await Assert.ThrowsAsync<OfflineProviderException>(() => tokens.GetTokenAsync(default).AsTask());
    }

    [Theory]
    [InlineData(false, true, "PROMPT_SHIELD_NOT_CONFIGURED")]
    [InlineData(true, false, "PROMPT_SHIELD_CAPABILITY_BINDING_INVALID")]
    public async Task Real_client_checks_configuration_before_resolving_any_token(
        bool enabled, bool bound, string failureCode)
    {
        using var transport = new OfflineHttpHandler();
        using var http = new HttpClient(transport) { BaseAddress = new(TestData.ShieldEndpoint) };
        var options = new PromptShieldOptions { Enabled = enabled, Endpoint = TestData.ShieldEndpoint };
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(bound ? TestData.ShieldConfiguration() : []).Build();
        var tokens = new ScriptedTokenProvider();
        var client = new PromptShieldClient(http, tokens, Options.Create(options),
            new BootstrapPromptShieldRuntimeBinding(configuration, () => options));
        var exception = await Assert.ThrowsAsync<PromptShieldException>(() =>
            client.EvaluateAsync("synthetic", Subject(), default));
        Assert.Equal(failureCode, exception.FailureCode);
        Assert.Equal(0, tokens.Calls);
        Assert.Equal(0, transport.Calls);
    }

    [Theory]
    [InlineData(200, "{\"userPromptAnalysis\":{\"attackDetected\":false}}", null, false)]
    [InlineData(200, "{\"userPromptAnalysis\":{\"attackDetected\":true}}", null, true)]
    [InlineData(200, "{\"userPromptAnalysis\":{\"attackDetected\":\"false\"}}", "PROMPT_SHIELD_INVALID_RESPONSE", false)]
    [InlineData(200, "not-json", "PROMPT_SHIELD_INVALID_RESPONSE", false)]
    [InlineData(403, "{}", "PROMPT_SHIELD_FORBIDDEN", false)]
    [InlineData(429, "{}", "PROMPT_SHIELD_THROTTLED", false)]
    [InlineData(500, "{}", "PROMPT_SHIELD_INVALID_STATUS", false)]
    public async Task Real_provider_client_only_trusts_explicit_boolean_decisions_over_fake_HTTP(
        int status, string body, string? failureCode, bool attack)
    {
        string? requestBody = null;
        using var transport = new OfflineHttpHandler
        {
            Respond = async (request, ct) =>
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Assert.Equal("m1offline.cognitiveservices.azure.com", request.RequestUri!.Host);
                requestBody = await request.Content!.ReadAsStringAsync(ct);
                return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body) };
            }
        };
        using var http = new HttpClient(transport) { BaseAddress = new(TestData.ShieldEndpoint) };
        var options = new PromptShieldOptions { Enabled = true, Endpoint = TestData.ShieldEndpoint };
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(TestData.ShieldConfiguration()).Build();
        var tokens = new ScriptedTokenProvider { Token = SyntheticToken() };
        var client = new PromptShieldClient(http, tokens, Options.Create(options),
            new BootstrapPromptShieldRuntimeBinding(configuration, () => options));
        if (failureCode is null)
            Assert.Equal(attack, (await client.EvaluateAsync("synthetic prompt", Subject(), default)).AttackDetected);
        else
            Assert.Equal(failureCode, (await Assert.ThrowsAsync<PromptShieldException>(() =>
                client.EvaluateAsync("synthetic prompt", Subject(), default))).FailureCode);
        Assert.Equal(1, transport.Calls);
        Assert.Equal(1, tokens.Calls);
        Assert.Equal("{\"userPrompt\":\"synthetic prompt\"}", requestBody);
        Assert.DoesNotContain(TestData.TenantUser, requestBody!);
    }

    private static PromptShieldSubject Subject() => new(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), "synthetic-correlation");

    private static AccessToken SyntheticToken()
    {
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{{\"oid\":\"{TestData.ShieldPrincipal}\"}}"))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return new AccessToken($"offline.{payload}.not-a-signature", new DateTimeOffset(TestData.Now.AddDays(1)));
    }

    private sealed class ScriptedTokenProvider : IPromptShieldTokenProvider
    {
        private int _calls;
        public AccessToken? Token { get; init; }
        public int Calls => Volatile.Read(ref _calls);
        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Interlocked.Increment(ref _calls) > 1)
                throw new OfflineProviderException();
            return ValueTask.FromResult(Token ?? throw new OfflineProviderException());
        }
    }
}
