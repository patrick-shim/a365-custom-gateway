using Gateway.AdminUi.Components;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Options;
using Gateway.AdminUi.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.FluentUI.AspNetCore.Components;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

var gatewayApiSection = builder.Configuration.GetSection(GatewayApiOptions.SectionName);
var gatewayApiScopes = gatewayApiSection
    .GetSection(nameof(GatewayApiOptions.Scopes))
    .Get<string[]>() ?? [];

builder.Services
    .AddAuthentication(options =>
    {
        options.DefaultAuthenticateScheme = CookieAuthenticationDefaults.AuthenticationScheme;
        options.DefaultSignInScheme = CookieAuthenticationDefaults.AuthenticationScheme;
        options.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
    })
    .AddMicrosoftIdentityWebApp(
        builder.Configuration.GetSection("EntraId"),
        openIdConnectScheme: OpenIdConnectDefaults.AuthenticationScheme,
        cookieScheme: CookieAuthenticationDefaults.AuthenticationScheme)
    .EnableTokenAcquisitionToCallDownstreamApi(gatewayApiScopes)
    .AddInMemoryTokenCaches();

builder.Services.Configure<CookieAuthenticationOptions>(
    CookieAuthenticationDefaults.AuthenticationScheme,
    options =>
    {
        options.AccessDeniedPath = "/access-denied";
        options.Cookie.HttpOnly = true;
        options.Cookie.SameSite = SameSiteMode.Lax;
        options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
        options.SlidingExpiration = true;
    });

builder.Services.Configure<OpenIdConnectOptions>(
    OpenIdConnectDefaults.AuthenticationScheme,
    options =>
    {
        options.ResponseType = "code";
        options.UsePkce = true;
        options.SaveTokens = false;
        options.TokenValidationParameters.NameClaimType = "name";
        options.TokenValidationParameters.RoleClaimType = "roles";
    });

builder.Services.AddGatewayAuthorization();
builder.Services.AddTransient<IClaimsTransformation, PortalRoleClaimsTransformation>();
builder.Services.AddCascadingAuthenticationState();

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

builder.Services.AddFluentUIComponents();
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<IGatewayAccessTokenProvider, GatewayAccessTokenProvider>();

builder.Services
    .AddOptions<GatewayApiOptions>()
    .Bind(gatewayApiSection)
    .Validate(
        options => options.BaseUrl is { IsAbsoluteUri: true },
        $"{GatewayApiOptions.SectionName}:BaseUrl must be an absolute URI.")
    .Validate(
        options => options.BaseUrl is not null &&
            (options.BaseUrl.Scheme == Uri.UriSchemeHttps || options.BaseUrl.IsLoopback),
        $"{GatewayApiOptions.SectionName}:BaseUrl must use HTTPS unless it targets loopback.")
    .Validate(
        options => options.Scopes is { Length: > 0 } &&
            options.Scopes.All(scope => !string.IsNullOrWhiteSpace(scope)),
        $"{GatewayApiOptions.SectionName}:Scopes must contain at least one delegated API scope.")
    .Validate(
        options => options.TimeoutSeconds is >= 5 and <= 120,
        $"{GatewayApiOptions.SectionName}:TimeoutSeconds must be between 5 and 120 seconds.")
    .ValidateOnStart();

builder.Services.AddHttpClient<IGatewayApiClient, GatewayApiClient>((services, client) =>
{
    var options = services.GetRequiredService<Microsoft.Extensions.Options.IOptions<GatewayApiOptions>>().Value;
    client.BaseAddress = options.BaseUrl;
    client.Timeout = TimeSpan.FromSeconds(options.TimeoutSeconds);
});

builder.Services.AddHealthChecks();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.UseHttpsRedirection();

app.UseAuthentication();
app.UseAuthorization();
app.UseAntiforgery();

app.MapGatewayAuthenticationEndpoints();
app.MapHealthChecks("/health").AllowAnonymous();

app.MapStaticAssets().AllowAnonymous();
app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();

public partial class Program;
