using System.Net;
using System.Text.Json;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Options;
using Gateway.AdminUi.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Hosting.StaticWebAssets;
using Microsoft.Extensions.Configuration.Memory;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.BrowserHost;

internal static class BrowserHostProgram
{
    public static async Task<int> Main(string[] args)
    {
        BrowserHostOptions options;
        try
        {
            options = BrowserHostOptions.Parse(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 2;
        }
        if (options.Help)
        {
            Console.WriteLine(BrowserHostOptions.HelpText);
            return 0;
        }
        if (options.SelfTest)
        {
            return await FixtureSelfTest.RunAsync();
        }

        var componentAssembly = typeof(App).Assembly.GetName().Name!;
        var runtimeManifest = Path.Combine(AppContext.BaseDirectory, $"{componentAssembly}.staticwebassets.runtime.json");
        var endpointManifest = Path.Combine(AppContext.BaseDirectory, $"{componentAssembly}.staticwebassets.endpoints.json");
        if (!File.Exists(runtimeManifest) || !File.Exists(endpointManifest))
        {
            Console.Error.WriteLine("Fresh production static asset manifests are required. Use Build-BrowserHost.ps1; --help describes the contract.");
            return 2;
        }

        // Deliberately never execute production Program or CreateBuilder defaults:
        // no appsettings, environment providers, user secrets, credentials or Azure SDK registration.
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions
        {
            Args = [],
            ApplicationName = componentAssembly,
            EnvironmentName = "BrowserFixture",
            ContentRootPath = AppContext.BaseDirectory
        });
        // EmptyBuilder still chains its in-memory hosting bootstrap configuration.
        // Replace that chain as well; only these explicit host values survive.
        builder.Configuration.Sources.Clear();
        builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            [HostDefaults.ApplicationKey] = componentAssembly,
            [HostDefaults.EnvironmentKey] = "BrowserFixture",
            [HostDefaults.ContentRootKey] = AppContext.BaseDirectory,
            [WebHostDefaults.PreventHostingStartupKey] = "true"
        });
        if (builder.Configuration.Sources.Any(source => source is not MemoryConfigurationSource))
        {
            throw new InvalidOperationException("Unexpected configuration source in isolated browser host: " +
                string.Join(", ", builder.Configuration.Sources.Select(source => source.GetType().FullName)));
        }
        using var tls = options.Https ? new FixtureTlsCertificate() : null;
        builder.WebHost.UseKestrel(server =>
        {
            server.AddServerHeader = false;
            server.Listen(IPAddress.Loopback, options.Port, listener =>
            {
                if (tls is not null) listener.UseHttps(tls.Certificate);
            });
        });
        builder.Logging.AddSimpleConsole().SetMinimumLevel(LogLevel.Warning);
        builder.Services.AddRouting();
        builder.Services.AddSingleton(new FixtureState(options));
        builder.Services.AddSingleton<IsolationGuards>();
        builder.Services.AddAuthentication(FixtureIdentity.Scheme)
            .AddScheme<AuthenticationSchemeOptions, FixtureAuthenticationHandler>(FixtureIdentity.Scheme, _ => { });
        builder.Services.AddGatewayAuthorization();
        builder.Services.AddCascadingAuthenticationState();
        builder.Services.AddRazorComponents().AddInteractiveServerComponents()
            .AddHubOptions(options =>
                options.MaximumReceiveMessageSize = PurviewCompanionInputLimits.MaximumHubMessageBytes);
        builder.Services.AddFluentUIComponents();
        builder.Services.AddDataProtection().UseEphemeralDataProtectionProvider();
        builder.Services.AddAntiforgery(antiforgery =>
        {
            antiforgery.HeaderName = "X-Gateway-CSRF";
            antiforgery.Cookie.Name = "BrowserFixture.Antiforgery";
            antiforgery.Cookie.SecurePolicy = options.Https ? CookieSecurePolicy.Always : CookieSecurePolicy.None;
        });
        builder.Services.AddHttpContextAccessor();
        builder.Services.AddScoped<RegistrationHandoffState>();
        builder.Services.AddSingleton(TimeProvider.System);
        builder.Services.Configure<GatewayApiOptions>(api =>
        {
            api.BaseUrl = new Uri("https://gateway.browser-fixture.invalid/");
            api.Scopes = ["api://browser-fixture.invalid/Gateway.Access"];
            api.TimeoutSeconds = 5;
        });
        builder.Services.AddScoped(services => FixtureGatewayApi.Create(services.GetRequiredService<FixtureState>()));
        builder.Services.RemoveAll<HttpClient>();
        builder.Services.RemoveAll<IHttpClientFactory>();
        builder.Services.RemoveAll<IHttpMessageHandlerFactory>();
        builder.Services.AddSingleton(services => new HttpClient(
            new DenyNetworkHandler(services.GetRequiredService<IsolationGuards>()), disposeHandler: true));
        builder.Services.AddSingleton<IHttpClientFactory, DenyClientFactory>();
        builder.Services.AddSingleton<IHttpMessageHandlerFactory, DenyClientFactory>();
        builder.Services.AddSingleton<IGatewayAccessTokenProvider, DenyAccessTokenProvider>();
        builder.Services.AddSingleton<IPurviewRuntimeExecutionClient, FixtureRuntimeExecution>();

        var assetsConfiguration = new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?> { [WebHostDefaults.StaticWebAssetsKey] = runtimeManifest }).Build();
        StaticWebAssetsLoader.UseStaticWebAssets(builder.Environment, assetsConfiguration);
        await using var app = builder.Build();
        app.Use(async (context, next) =>
        {
            if (context.Connection.RemoteIpAddress is not { } remote || !IPAddress.IsLoopback(remote) ||
                context.Request.Host.Host != "127.0.0.1" ||
                context.Request.Host.Port != context.Connection.LocalPort)
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            if (context.Request.Headers.Origin is { Count: > 0 } origin &&
                !string.Equals(origin.ToString(), $"{context.Request.Scheme}://{context.Request.Host}", StringComparison.Ordinal))
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            context.Response.Headers.ContentSecurityPolicy =
                $"default-src 'self'; connect-src 'self' {(context.Request.IsHttps ? "wss" : "ws")}://{context.Request.Host}; " +
                "img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; " +
                "base-uri 'self'; form-action 'self'; object-src 'none'; frame-ancestors 'none'";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            context.Response.Headers["Referrer-Policy"] = "no-referrer";
            if (!Path.HasExtension(context.Request.Path))
            {
                context.Response.Headers.CacheControl = "no-store";
            }
            if (context.Request.Path.StartsWithSegments("/__fixture") && HttpMethods.IsPost(context.Request.Method) &&
                (context.Request.Headers["X-Browser-Fixture"] != "1" || !context.Request.HasJsonContentType()))
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            await next(context);
        });
        app.UseAuthentication();
        app.UseAuthorization();
        app.UseAntiforgery();

        app.MapGet("/__fixture/health", (FixtureState state, IsolationGuards guards,
            Microsoft.Extensions.Options.IOptions<GatewayApiOptions> api) => Results.Ok(new
        {
            status = "ready",
            synthetic = true,
            componentAssembly,
            componentModuleId = typeof(App).Assembly.ManifestModule.ModuleVersionId,
            configurationSources = builder.Configuration.Sources.Select(source => source.GetType().Name).ToArray(),
            gatewayApiBaseUrl = api.Value.BaseUrl,
            state.Generation,
            guards = guards.Snapshot()
        })).AllowAnonymous();
        app.MapGet("/__fixture/catalog", () => FixtureCatalog.Contract()).AllowAnonymous();
        app.MapGet("/__fixture/state", (FixtureState state, IsolationGuards guards) =>
            Results.Ok(new { fixture = state.Snapshot(), guards = guards.Snapshot() })).AllowAnonymous();
        app.MapPost("/__fixture/reset", (FixtureResetRequest request, FixtureState state) =>
            Control(() => state.Reset(request))).AllowAnonymous();
        app.MapPost("/__fixture/operation", (FixtureOperationRequest request, FixtureState state) =>
            Control(() => state.SetOperation(request))).AllowAnonymous();
        app.MapPost("/__fixture/read-errors", (FixtureReadErrorsRequest request, FixtureState state) =>
            Control(() => state.SetReadErrors(request))).AllowAnonymous();
        app.MapPost("/__fixture/protection", (FixtureProtectionControl request, FixtureState state) =>
            Control(() => state.AdvanceProtection(request))).AllowAnonymous();
        app.MapPost("/__fixture/shutdown", (HttpContext context, IHostApplicationLifetime lifetime) =>
        {
            context.Response.OnCompleted(() => { lifetime.StopApplication(); return Task.CompletedTask; });
            return Results.Accepted();
        }).AllowAnonymous();
        app.MapMethods("/authentication/{**path}", ["GET", "POST"], () => Results.Conflict(new
        {
            error = "Synthetic browser host never authenticates with Entra. Reset the fixture role and reopen the same local route."
        })).AllowAnonymous();

        app.MapStaticAssets(endpointManifest).AllowAnonymous();
        app.MapPurviewRuntimePortalEndpoints();
        app.MapRazorComponents<App>().AddInteractiveServerRenderMode();
        await app.StartAsync();
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!
            .Addresses.Single();
        Console.WriteLine("BROWSER_FIXTURE_READY " + JsonSerializer.Serialize(new
        {
            url = address,
            scenario = options.Scenario,
            role = options.Role,
            publicCertificatePath = tls?.PublicCertificatePath,
            synthetic = true
        }));
        await app.WaitForShutdownAsync();
        return 0;
    }

    private static IResult Control(Func<object> action)
    {
        try { return Results.Ok(action()); }
        catch (ArgumentException exception) { return Results.BadRequest(new { error = exception.Message }); }
    }
}
