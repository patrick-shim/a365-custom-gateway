using System.Reflection;
using System.Security.Claims;
using Bunit;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.FluentUI.AspNetCore.Components;
using Microsoft.JSInterop;

namespace Gateway.AdminUi.Tests.Fixtures;

internal sealed class UnexpectedUiFixtureCallException(string message) : InvalidOperationException(message);

public class ScriptedGatewayApi : DispatchProxy
{
    private readonly Queue<(string Method, Func<object?[], object> Respond)> expected = new();
    public List<string> Calls { get; } = [];
    public List<string> UnexpectedCalls { get; } = [];

    public static (IGatewayApiClient Api, ScriptedGatewayApi Script) Create()
    {
        var api = Create<IGatewayApiClient, ScriptedGatewayApi>();
        return (api, (ScriptedGatewayApi)api);
    }

    public void Expect<T>(string method, Func<object?[], Task<T>> respond) =>
        expected.Enqueue((method, arguments => respond(arguments)));

    public void Return<T>(string method, T value, Action<object?[]>? inspect = null) =>
        Expect(method, arguments =>
        {
            inspect?.Invoke(arguments);
            return Task.FromResult(value);
        });

    protected override object Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        var name = targetMethod!.Name;
        if (!expected.TryPeek(out var next) || next.Method != name)
        {
            UnexpectedCalls.Add(name);
            throw new UnexpectedUiFixtureCallException("Unscripted Gateway API call: no HTTP fallback is available.");
        }
        expected.Dequeue();
        Calls.Add(name);
        return next.Respond(args ?? []);
    }

    public void AssertComplete()
    {
        Assert.Empty(expected);
        Assert.Empty(UnexpectedCalls);
    }
}

internal sealed class DenyUiNetworkHandler : HttpMessageHandler
{
    public int Attempts { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Attempts++;
        throw new UnexpectedUiFixtureCallException("UI fixture network access is forbidden.");
    }
}

internal sealed class DenyUiClientFactory : IHttpClientFactory
{
    public HttpClient CreateClient(string name) =>
        throw new UnexpectedUiFixtureCallException("UI fixtures cannot create a provider HTTP client.");
}

internal sealed class DenyUiAccessTokenProvider : IGatewayAccessTokenProvider
{
    public Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default) =>
        throw new UnexpectedUiFixtureCallException("UI fixtures cannot acquire real access tokens.");
}

internal sealed class AdminUiFixture : BunitContext
{
    public static readonly Guid Tenant = Guid.Parse("11111111-1111-4111-8111-111111111111");
    public static readonly Guid Actor = Guid.Parse("22222222-2222-4222-8222-222222222222");
    public IGatewayApiClient Api { get; }
    public ScriptedGatewayApi Script { get; }
    public DenyUiNetworkHandler Network { get; } = new();

    public AdminUiFixture(string role = GatewayRoles.Administrator)
    {
        (Api, Script) = ScriptedGatewayApi.Create();
        Services.AddFluentUIComponents();
        Services.AddSingleton(Api);
        Services.AddSingleton(new HttpClient(Network, disposeHandler: true));
        Services.AddSingleton<IHttpClientFactory, DenyUiClientFactory>();
        Services.AddSingleton<IGatewayAccessTokenProvider, DenyUiAccessTokenProvider>();
        // bUnit never runs JavaScript. Fluent UI display/focus interop may be stubbed;
        // the sample module below has a separate finite invocation script.
        JSInterop.Mode = JSRuntimeMode.Loose;
        var authorization = AddAuthorization();
        authorization.SetAuthorized("Offline fixture");
        authorization.SetRoles(role);
        authorization.SetClaims(new Claim("tid", Tenant.ToString("D")), new Claim("oid", Actor.ToString("D")));
    }

    public void AssertComplete()
    {
        Script.AssertComplete();
        Assert.Equal(0, Network.Attempts);
    }

    public void RoutePrivateSampleModule(ScriptedJsObject module)
    {
        var registration = Services.Last(item => item.ServiceType == typeof(IJSRuntime));
        Services.RemoveAll<IJSRuntime>();
        Services.AddSingleton<IJSRuntime>(provider => new PrivateSampleRuntime(
            (IJSRuntime)(registration.ImplementationInstance
                ?? registration.ImplementationFactory?.Invoke(provider)
                ?? ActivatorUtilities.CreateInstance(provider, registration.ImplementationType!)),
            module));
    }

    public static Task ClickAsync<T>(IRenderedComponent<T> component, string label) where T : class, IComponent
    {
        var button = component.FindComponents<FluentButton>()
            .Single(item => item.Find("fluent-button").TextContent.Trim() == label);
        return component.InvokeAsync(() => button.Instance.OnClick.InvokeAsync(new MouseEventArgs()));
    }
}

internal sealed class PrivateSampleRuntime(IJSRuntime displayInterop, ScriptedJsObject module) : IJSRuntime
{
    private int imports;
    public ValueTask<TValue> InvokeAsync<TValue>(string identifier, object?[]? args) =>
        InvokeAsync<TValue>(identifier, CancellationToken.None, args);

    public ValueTask<TValue> InvokeAsync<TValue>(string identifier, CancellationToken cancellationToken, object?[]? args)
    {
        if (identifier != "import" || args is not ["./purview-runtime-test.js"])
            return displayInterop.InvokeAsync<TValue>(identifier, cancellationToken, args);
        cancellationToken.ThrowIfCancellationRequested();
        if (++imports != 1)
            throw new UnexpectedUiFixtureCallException("The private sample module import budget was exhausted.");
        return ValueTask.FromResult((TValue)(object)module);
    }
}

internal sealed class ScriptedJsObject : IJSObjectReference
{
    private readonly Queue<(string Method, object? Result)> expected = new();
    private int cleanupCalls;
    private bool disposed;
    public List<string> Invocations { get; } = [];
    public List<string> UnexpectedCalls { get; } = [];

    public void Expect(string method, object? result) => expected.Enqueue((method, result));
    public ValueTask<TValue> InvokeAsync<TValue>(string identifier, object?[]? args) =>
        InvokeAsync<TValue>(identifier, CancellationToken.None, args);

    public ValueTask<TValue> InvokeAsync<TValue>(string identifier, CancellationToken cancellationToken, object?[]? args)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Invocations.Add(identifier);
        if (identifier is "clear" or "dispose" && ++cleanupCalls <= 4)
            return ValueTask.FromResult(default(TValue)!);
        if (!expected.TryPeek(out var next) || next.Method != identifier)
        {
            UnexpectedCalls.Add(identifier);
            throw new UnexpectedUiFixtureCallException("Unscripted private-sample interop call.");
        }
        expected.Dequeue();
        return ValueTask.FromResult(next.Result is null ? default! : (TValue)next.Result);
    }

    public ValueTask DisposeAsync()
    {
        Assert.False(disposed);
        disposed = true;
        return ValueTask.CompletedTask;
    }

    public void AssertComplete()
    {
        Assert.Empty(expected);
        Assert.Empty(UnexpectedCalls);
    }
}
