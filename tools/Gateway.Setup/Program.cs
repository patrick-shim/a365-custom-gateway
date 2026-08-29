using System.Net;
using Gateway.Setup;
using Gateway.Setup.Components;
using Gateway.Setup.Security;
using Gateway.Setup.Services;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.FluentUI.AspNetCore.Components;

var hostArguments = SetupHostArguments.Parse(args);
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
builder.WebHost.UseStaticWebAssets();

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
    options.Cookie.Name = $"a365_gateway_setup_antiforgery_{cookieSuffix}";
    options.Cookie.HttpOnly = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
});

builder.Services.AddRazorComponents().AddInteractiveServerComponents();
builder.Services.AddFluentUIComponents();
builder.Services.AddSetupWorkflow();

var app = builder.Build();

app.UseSession();
app.UseMiddleware<SetupBoundaryMiddleware>();
app.UseAntiforgery();

app.MapStaticAssets();
app.MapGet("/", () => Results.Redirect("/setup/welcome", permanent: false));
app.MapRazorComponents<App>().AddInteractiveServerRenderMode();

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

if (hostArguments.OpenBrowser)
{
    app.Services.GetRequiredService<ISetupBrowserLauncher>().TryOpen(initialAddress);
}

await app.WaitForShutdownAsync();

public partial class Program;
