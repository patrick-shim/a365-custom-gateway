using System.Security.Claims;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.BrowserHost;

internal sealed class UnexpectedFixtureCallException(string message) : InvalidOperationException(message);

internal sealed class IsolationGuards
{
    private int httpAttempts;
    private int clientFactoryAttempts;
    private int tokenAttempts;
    private int runtimeAttempts;

    public object Snapshot() => new
    {
        httpAttempts = Volatile.Read(ref httpAttempts),
        clientFactoryAttempts = Volatile.Read(ref clientFactoryAttempts),
        tokenAttempts = Volatile.Read(ref tokenAttempts),
        runtimeAttempts = Volatile.Read(ref runtimeAttempts),
        realNetworkFallback = false,
        realAuthentication = false,
        productionHostConfiguration = false
    };

    public UnexpectedFixtureCallException RejectHttp()
    {
        Interlocked.Increment(ref httpAttempts);
        return new("Browser fixture HTTP transport is terminal: no request was sent.");
    }

    public UnexpectedFixtureCallException RejectClientFactory()
    {
        Interlocked.Increment(ref clientFactoryAttempts);
        return new("Browser fixture cannot create a provider HTTP client.");
    }

    public UnexpectedFixtureCallException RejectToken()
    {
        Interlocked.Increment(ref tokenAttempts);
        return new("Browser fixture cannot acquire a real access token.");
    }

    public UnexpectedFixtureCallException RejectRuntime()
    {
        Interlocked.Increment(ref runtimeAttempts);
        return new("Browser fixture does not execute provider runtime tests.");
    }
}

internal sealed class DenyNetworkHandler(IsolationGuards guards) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        throw guards.RejectHttp();
}

internal sealed class DenyClientFactory(IsolationGuards guards) : IHttpClientFactory, IHttpMessageHandlerFactory
{
    public HttpClient CreateClient(string name) => throw guards.RejectClientFactory();
    public HttpMessageHandler CreateHandler(string name) => throw guards.RejectClientFactory();
}

internal sealed class DenyAccessTokenProvider(IsolationGuards guards) : IGatewayAccessTokenProvider
{
    public Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default) =>
        throw guards.RejectToken();
}

internal sealed class DenyRuntimeExecution(IsolationGuards guards) : IPurviewRuntimeExecutionClient
{
    public Task<PurviewRuntimeTestResultResponse> ExecuteAsync(ClaimsPrincipal user, Guid profileId,
        RuntimePortalExecutionRequest request, CancellationToken cancellationToken) =>
        throw guards.RejectRuntime();
}
