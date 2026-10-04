using System.Net;
using Gateway.Setup;
using Microsoft.AspNetCore.Antiforgery;
using System.Text.Json;
using Gateway.Setup.Security;
using Gateway.Setup.Services;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.FileProviders;

SetupHostArguments hostArguments;
try
{
    hostArguments = SetupHostArguments.Parse(args);
}
catch (ArgumentException exception)
{
    Console.Error.WriteLine(exception.Message);
    Console.Error.WriteLine(SetupHostArguments.Usage);
    return 2;
}

if (hostArguments.ShowHelp)
{
    Console.WriteLine(SetupHostArguments.Usage);
    return 0;
}

var repository = RepositoryLayout.Resolve(hostArguments.RepositoryRoot);
var nonceIssue = SessionNonceGate.Create();
var cookieSuffix = Guid.NewGuid().ToString("N")[..8];

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = []
});

builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;
    options.Listen(LoopbackBindingPolicy.CreateEndpoint(), listen =>
    {
        listen.Protocols = HttpProtocols.Http1;
    });
});
builder.WebHost.UseSetting(WebHostDefaults.PreventHostingStartupKey, "true");


builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.AspNetCore.Session", LogLevel.Error);
builder.Logging.AddFilter("Microsoft.AspNetCore.Antiforgery", LogLevel.Critical);

builder.Services.AddSingleton(repository);
builder.Services.AddSingleton(nonceIssue.Gate);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<SetupActivityTracker>();
builder.Services.AddSingleton<ISetupBrowserLauncher, SetupBrowserLauncher>();
builder.Services.AddHostedService<SetupShutdownService>();

builder.Services.AddDataProtection().UseEphemeralDataProtectionProvider();
builder.Services.AddDistributedMemoryCache();
builder.Services.AddSession(options =>
{
    options.Cookie.Name = $"a365_gateway_setup_session_{cookieSuffix}";
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
    options.IdleTimeout = TimeSpan.FromMinutes(45);
});
builder.Services.AddAntiforgery(options =>
{
    options.HeaderName = "X-Setup-Csrf";
    options.Cookie.Name = $"a365_gateway_setup_antiforgery_{cookieSuffix}";
    options.Cookie.HttpOnly = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
});



builder.Services.AddSingleton<SetupEngine>();

var app = builder.Build();

app.UseSession();
app.UseMiddleware<SetupBoundaryMiddleware>();
app.UseAntiforgery();

var assets = Path.Combine(repository.RootPath, "web", "setup", "dist");
if (!File.Exists(Path.Combine(assets,"index.html")))
    throw new InvalidOperationException("Build the React installer first with gateway gui.");
app.UseStaticFiles(new StaticFileOptions { FileProvider=new PhysicalFileProvider(assets) });
app.MapGet("/api/setup/session", (HttpContext context, IAntiforgery csrf) =>
    Results.Ok(new {token=csrf.GetAndStoreTokens(context).RequestToken}));
app.MapGet("/api/setup/progress", (SetupEngine engine) => Results.Ok(engine.Snapshot()));
app.MapPost("/api/setup/operations", async (HttpContext context, IAntiforgery csrf, SetupEngine engine) => {
    try { await csrf.ValidateRequestAsync(context); }
    catch(AntiforgeryValidationException) { return Results.BadRequest(new {message="Setup session expired. Reopen setup."}); }
    if(context.Request.ContentLength is null or > 32768) return Results.BadRequest(new {message="Invalid setup request size."});
    SetupRequest? request;
    try { request=await JsonSerializer.DeserializeAsync<SetupRequest>(context.Request.Body, new JsonSerializerOptions(JsonSerializerDefaults.Web), context.RequestAborted); }
    catch(JsonException) { return Results.BadRequest(new {message="Invalid setup request."}); }
    if(request is null) return Results.BadRequest();
    try { return engine.Start(request.Action,request.Input,request.Fingerprint) ? Results.Accepted() : Results.Conflict(new {message="Setup is already running."}); }
    catch(ArgumentException exception) { return Results.BadRequest(new {message=exception.Message}); }
});
app.MapFallback(() => Results.File(Path.Combine(assets,"index.html"),"text/html"));
await app.StartAsync();

var addresses = app.Services
    .GetRequiredService<IServer>()
    .Features
    .Get<IServerAddressesFeature>()?
    .Addresses;
var baseAddressText = addresses?.SingleOrDefault(address =>
    address.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));

if (!Uri.TryCreate(baseAddressText, UriKind.Absolute, out var baseAddress) ||
    !baseAddress.IsLoopback ||
    baseAddress.Port <= 0)
{
    await app.StopAsync();
    throw new InvalidOperationException("Gateway Setup could not resolve its loopback listener.");
}

var initialAddress = new UriBuilder(baseAddress)
{
    Path = "/setup",
    Query = $"nonce={Uri.EscapeDataString(nonceIssue.Nonce)}"
}.Uri;

Console.WriteLine("A365 Gateway Setup is available only on this computer.");
Console.WriteLine($"Open this one-time URL if the browser does not start: {initialAddress.AbsoluteUri}");
Console.WriteLine("Keep this terminal open. Azure and Microsoft 365 sign-in prompts remain in their official CLI/browser flows.");

SetupBrowserLauncher.OpenIfRequested(
    hostArguments,
    app.Services.GetRequiredService<ISetupBrowserLauncher>(),
    initialAddress);

await app.WaitForShutdownAsync();
return 0;

public partial class Program;

public sealed record SetupRequest(string Action, JsonElement? Input, string? Fingerprint);
