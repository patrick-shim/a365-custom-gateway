extern alias GatewayApi;

using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using Gateway.Application.Protection;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Gateway.TestSupport;
using MediatR;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests;

public sealed class M5ForwardedHttpsTests
{
    private static readonly Guid Tenant = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid Actor = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid Profile = Guid.Parse("33333333-3333-4333-8333-333333333333");
    private static readonly Guid Operation = Guid.Parse("44444444-4444-4444-8444-444444444444");
    private static readonly Guid Idempotency = Guid.Parse("55555555-5555-4555-8555-555555555555");
    private const string RowVersion = "AAAAAAAAAAE=";

    [Theory]
    [InlineData("review")]
    [InlineData("confirmation")]
    [InlineData("execute")]
    [InlineData("readback")]
    public async Task Trusted_tls_terminating_proxy_reaches_the_authenticated_runtime_workflow(string action)
    {
        await using var factory = new ProxyApiFactory("100.100.1.34", "http", "100.100.0.0/17");
        factory.ExpectAction(action);
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request(action, "https"));
        Assert.Equal(action == "confirmation" ? HttpStatusCode.OK : HttpStatusCode.NotFound, response.StatusCode);
        factory.AssertComplete();
    }

    [Theory]
    [InlineData("203.0.113.20", "https")]
    [InlineData("127.0.0.1", "https")]
    [InlineData("100.100.194.65", "https")]
    [InlineData("100.100.1.34", "http")]
    [InlineData("100.100.1.34", "http, http")]
    public async Task Untrusted_or_insecure_forwarding_cannot_confirm_private_samples(string remote, string forwarded)
    {
        await using var factory = new ProxyApiFactory(remote, "http", "100.100.0.0/17");
        factory.ExpectConfirmationReadOnly();
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request("confirmation", forwarded));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        factory.AssertComplete();
    }

    [Theory]
    [InlineData("review")]
    [InlineData("execute")]
    public async Task Forwarded_https_from_an_untrusted_peer_does_not_admit_sample_posts(string action)
    {
        await using var factory = new ProxyApiFactory("203.0.113.20", "http", "100.100.0.0/17");
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request(action, "https"));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        factory.AssertComplete();
    }

    [Fact]
    public async Task Direct_https_keeps_working_without_proxy_configuration()
    {
        await using var factory = new ProxyApiFactory("203.0.113.20", "https", null);
        factory.ExpectAction("readback");
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request("readback", null));
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        factory.AssertComplete();
    }

    [Fact]
    public async Task Trusted_forwarding_does_not_bypass_authentication()
    {
        await using var factory = new ProxyApiFactory("100.100.1.34", "http", "100.100.0.0/17");
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var request = Request("review", "https");
        request.Headers.Remove("X-Synthetic-Administrator");
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        factory.AssertComplete();
    }

    [Fact]
    public async Task Mapped_ipv4_proxy_addresses_preserve_the_same_trust_boundary()
    {
        await using var factory = new ProxyApiFactory("::ffff:100.100.1.34", "http", "100.100.0.0/17");
        factory.ExpectAction("confirmation");
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request("confirmation", "https"));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        factory.AssertComplete();
    }

    [Fact]
    public async Task No_configured_proxy_does_not_trust_a_forwarded_https_claim()
    {
        await using var factory = new ProxyApiFactory("100.100.1.34", "http", null);
        factory.ExpectConfirmationReadOnly();
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request("confirmation", "https"));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        factory.AssertComplete();
    }

    [Fact]
    public async Task A_missing_network_peer_does_not_establish_proxy_authority()
    {
        await using var factory = new ProxyApiFactory(null, "http", "100.100.0.0/17");
        factory.ExpectConfirmationReadOnly();
        using var client = factory.CreateClient(new() { AllowAutoRedirect = false });
        using var response = await client.SendAsync(Request("confirmation", "https"));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        factory.AssertComplete();
    }

    [Theory]
    [InlineData("0.0.0.0/0")]
    [InlineData("::/0")]
    [InlineData("::ffff:0.0.0.0/96")]
    [InlineData("::ffff:0:0/96")]
    [InlineData("100.100.1.34/17")]
    [InlineData("not-a-network")]
    [InlineData("")]
    public void Malformed_or_trust_all_configuration_fails_startup(string network)
    {
        using var factory = new ProxyApiFactory("100.100.1.34", "http", network);
        Assert.Throws<OptionsValidationException>(() => factory.CreateClient());
    }

    [Fact]
    public void Proxy_configuration_is_bounded_and_does_not_accept_duplicate_ranges()
    {
        Assert.False(Gateway.Api.Options.GatewayIngressOptions.IsValid(new()
        {
            TrustedProxyNetworks = ["100.100.0.0/17", "100.100.0.0/17"]
        }));
        Assert.False(Gateway.Api.Options.GatewayIngressOptions.IsValid(new()
        {
            TrustedProxyNetworks = Enumerable.Range(1, 9).Select(value => $"10.0.0.{value}/32").ToArray()
        }));
    }

    [Fact]
    public async Task Forwarding_changes_only_the_scheme_not_the_host_or_client_authority()
    {
        await using var factory = new ProxyApiFactory("100.100.1.34", "http", "100.100.0.0/17");
        using var client = factory.CreateClient(new()
        {
            AllowAutoRedirect = false, BaseAddress = new Uri("http://gateway.invalid")
        });
        using var request = new HttpRequestMessage(HttpMethod.Get, "openapi/v1.json");
        request.Headers.Add("X-Forwarded-Proto", "https");
        request.Headers.Add("X-Forwarded-Host", "attacker.invalid");
        request.Headers.Add("X-Forwarded-For", "203.0.113.20");
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        using var document = System.Text.Json.JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        Assert.Equal("https://gateway.invalid/", document.RootElement.GetProperty("servers")[0].GetProperty("url").GetString());
        var forwarding = factory.Services.GetRequiredService<IOptions<ForwardedHeadersOptions>>().Value;
        Assert.Equal(Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedProto, forwarding.ForwardedHeaders);
        Assert.Equal(1, forwarding.ForwardLimit);
        Assert.Empty(forwarding.KnownProxies);
        Assert.Equal("100.100.0.0/17", Assert.Single(forwarding.KnownIPNetworks).ToString());
        factory.AssertComplete();
    }

    private static HttpRequestMessage Request(string action, string? forwarded)
    {
        var path = action switch
        {
            "review" => $"api/v1/protection/purview/dlp-profiles/{Profile:D}:review-runtime-test",
            "execute" => $"api/v1/protection/purview/dlp-profiles/{Profile:D}:test-runtime",
            "readback" => $"api/v1/protection/runtime-tests/{Operation:D}",
            _ => "api/v1/protection/operation-reviews:confirm"
        };
        var request = new HttpRequestMessage(action == "readback" ? HttpMethod.Get : HttpMethod.Post, path);
        request.Headers.Add("X-Synthetic-Administrator", "true");
        if (forwarded is not null) request.Headers.Add("X-Forwarded-Proto", forwarded);
        request.Headers.TryAddWithoutValidation("If-Match", RowVersion);
        request.Headers.Add("Idempotency-Key", Idempotency.ToString("D"));
        request.Content = action switch
        {
            "review" => JsonContent.Create(new { profileId = Profile, expectedRowVersion = RowVersion }),
            "execute" => JsonContent.Create(new
            {
                confirmationTokenId = Operation, confirmationToken = "synthetic-confirmation",
                idempotencyKey = Idempotency, expectedRowVersion = RowVersion, samples = Array.Empty<object>()
            }),
            "confirmation" => JsonContent.Create(new ConfirmProtectionOperationReviewRequest(Operation, "synthetic-review")),
            _ => null
        };
        return request;
    }

    private sealed class ProxyApiFactory(string? remote, string scheme, string? trustedNetwork)
        : WebApplicationFactory<GatewayApi::Program>
    {
        private readonly (ISender Api, M4ReadProtocol<ISender> Script) sender = M4ReadProtocol<ISender>.Create();
        private readonly (IPurviewRuntimeTestRepository Api, M4ReadProtocol<IPurviewRuntimeTestRepository> Script) store =
            M4ReadProtocol<IPurviewRuntimeTestRepository>.Create();
        private readonly (IProtectionAdminOperationRepository Api, M4ReadProtocol<IProtectionAdminOperationRepository> Script) operations =
            M4ReadProtocol<IProtectionAdminOperationRepository>.Create();
        private readonly (IAuditEventRepository Api, M4ReadProtocol<IAuditEventRepository> Script) audit =
            M4ReadProtocol<IAuditEventRepository>.Create();
        private readonly (IUnitOfWork Api, M4ReadProtocol<IUnitOfWork> Script) unit =
            M4ReadProtocol<IUnitOfWork>.Create();
        private readonly (IPurviewRuntimeTestRunner Api, M4ReadProtocol<IPurviewRuntimeTestRunner> Script) runner =
            M4ReadProtocol<IPurviewRuntimeTestRunner>.Create();

        public void ExpectAction(string action)
        {
            if (action == "review")
                store.Script.Return<PurviewRuntimeTestSnapshot?>(nameof(IPurviewRuntimeTestRepository.LoadFreshSnapshotAsync), null);
            else if (action == "confirmation")
            {
                ExpectConfirmationReadOnly();
                sender.Script.Return(nameof(ISender.Send),
                    new ProtectionOperationConfirmationResponse(Operation, Operation, "synthetic-confirmation", TestData.Now.AddMinutes(5)));
            }
            else
                operations.Script.Return<ProtectionAdminOperation?>(nameof(IProtectionAdminOperationRepository.GetByIdAsync), null);
        }

        public void ExpectConfirmationReadOnly() => sender.Script.Return(nameof(ISender.Send),
            new ProtectionAdminOperationResponse(new ProtectionAdminOperationDto(
                Operation, 1, "TestDlpRuntime", "AwaitingConfirmation", Tenant, Actor.ToString("D"),
                "DlpProfile", Profile.ToString("D"), "sha256:" + new string('a', 64), Idempotency,
                RowVersion, "NotApplicable", 0, 1, null, false, false, Idempotency, null, null, null,
                [], TestData.Now, null, null, TestData.Now, [], RowVersion)));

        public void AssertComplete()
        {
            sender.Script.AssertComplete();
            store.Script.AssertComplete();
            operations.Script.AssertComplete();
            audit.Script.AssertComplete();
            unit.Script.AssertComplete();
            runner.Script.AssertComplete();
        }

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Testing");
            builder.ConfigureAppConfiguration((_, configuration) =>
            {
                var values = new Dictionary<string, string?>
                {
                    ["EntraId:TenantId"] = Tenant.ToString("D"),
                    ["EntraId:ClientId"] = "66666666-6666-4666-8666-666666666666",
                    ["EntraId:Audience"] = "66666666-6666-4666-8666-666666666666"
                };
                if (trustedNetwork is not null)
                    values["GatewayIngress:TrustedProxyNetworks:0"] = trustedNetwork;
                configuration.AddInMemoryCollection(values);
            });
            builder.ConfigureTestServices(services =>
            {
                foreach (var descriptor in services.Where(descriptor =>
                             descriptor.ServiceType == typeof(IHostedService) &&
                             descriptor.ImplementationType?.Namespace?.StartsWith("Gateway.", StringComparison.Ordinal) == true).ToArray())
                    services.Remove(descriptor);
                services.RemoveAll<IAuthenticationHandlerProvider>();
                services.AddSingleton<IAuthenticationHandlerProvider, SyntheticAuthentication>();
                services.RemoveAll<IProtectionAdminOperationLockProvider>();
                services.AddSingleton<IProtectionAdminOperationLockProvider, SyntheticLocks>();
                services.RemoveAll<ISender>();
                services.AddSingleton(sender.Api);
                services.RemoveAll<IProtectionAdminOperationRepository>();
                services.AddSingleton(operations.Api);
                services.RemoveAll<PurviewRuntimeTestService>();
                services.AddSingleton(new PurviewRuntimeTestService(store.Api, operations.Api, audit.Api,
                    unit.Api, new ProtectionOperationTokenService(TimeProvider.System), runner.Api, TimeProvider.System));
                services.AddSingleton<IStartupFilter>(new ProxyConnection(remote, scheme));
                services.ConfigureHttpClientDefaults(client =>
                    client.ConfigurePrimaryHttpMessageHandler(() => new DenyTransport()));
            });
        }
    }

    private sealed class ProxyConnection(string? remote, string scheme) : IStartupFilter
    {
        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => application =>
        {
            application.Use((context, continuation) =>
            {
                context.Connection.RemoteIpAddress = remote is null ? null : IPAddress.Parse(remote);
                context.Request.Scheme = scheme;
                return continuation(context);
            });
            next(application);
        };
    }

    private sealed class SyntheticAuthentication : IAuthenticationHandlerProvider
    {
        public async Task<IAuthenticationHandler?> GetHandlerAsync(HttpContext context, string authenticationScheme)
        {
            var handler = new SyntheticHandler();
            await handler.InitializeAsync(new(authenticationScheme, authenticationScheme, typeof(SyntheticHandler)), context);
            return handler;
        }
    }

    private sealed class SyntheticHandler : IAuthenticationHandler
    {
        private HttpContext context = null!;
        private AuthenticationScheme scheme = null!;
        public Task InitializeAsync(AuthenticationScheme value, HttpContext httpContext)
        {
            scheme = value;
            context = httpContext;
            return Task.CompletedTask;
        }
        public Task<AuthenticateResult> AuthenticateAsync() => Task.FromResult(
            context.Request.Headers["X-Synthetic-Administrator"] == "true"
                ? AuthenticateResult.Success(new(new ClaimsPrincipal(new ClaimsIdentity(
                    [new("tid", Tenant.ToString("D")), new("oid", Actor.ToString("D")),
                        new("scp", "access_as_user"), new("roles", "Gateway.Administrator")],
                    "synthetic-proxy-fixture", "name", "roles")), scheme.Name))
                : AuthenticateResult.NoResult());
        public Task ChallengeAsync(AuthenticationProperties? properties)
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return Task.CompletedTask;
        }
        public Task ForbidAsync(AuthenticationProperties? properties)
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return Task.CompletedTask;
        }
    }

    private sealed class SyntheticLocks : IProtectionAdminOperationLockProvider
    {
        public Task<IAsyncDisposable> AcquireExecutionAsync(Guid operationId, CancellationToken ct) =>
            Task.FromResult<IAsyncDisposable>(new Lease());
        public Task<IProtectionAdminIdempotencyLease> AcquireIdempotencyAsync(
            EntraTenantId tenantId, ProtectionIdempotencyKey idempotencyKey, CancellationToken ct) =>
            Task.FromResult<IProtectionAdminIdempotencyLease>(new Lease());
        private sealed class Lease : IProtectionAdminIdempotencyLease
        {
            public Task CompleteAsync(CancellationToken ct) => Task.CompletedTask;
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }

    private sealed class DenyTransport : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            throw new OfflineProviderException();
    }
}
