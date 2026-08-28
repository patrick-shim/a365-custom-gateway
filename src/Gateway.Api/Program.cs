using Gateway.Agent365;
using Gateway.Api.Authentication;
using Gateway.Api.Authorization;
using Gateway.Api.Middleware;
using Gateway.Api.Options;
using Gateway.Application;
using Gateway.Infrastructure;
using Gateway.Infrastructure.Persistence;
using Gateway.Observability;
using Gateway.Purview;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Identity.Web;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddMicrosoftIdentityWebApiAuthentication(builder.Configuration, "EntraId")
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();
builder.Services
    .AddAuthentication()
    .AddScheme<AuthenticationSchemeOptions, GatewayAgentApiKeyAuthenticationHandler>(
        GatewayAgentApiKeyDefaults.AuthenticationScheme,
        _ => { });

builder.Services.ConfigureAuthorizationPolicies();

builder.Services
    .AddOptions<ProvisioningOptions>()
    .Bind(builder.Configuration.GetSection(ProvisioningOptions.SectionName));
builder.Services
    .AddOptions<Agent365DelegatedRegistryOptions>()
    .Bind(builder.Configuration.GetSection(Agent365DelegatedRegistryOptions.SectionName))
    .Validate(options =>
    {
        var scopes = options.Scopes
            .Where(scope => !string.IsNullOrWhiteSpace(scope))
            .ToHashSet(StringComparer.Ordinal);
        return scopes.SetEquals(new[]
        {
            "https://graph.microsoft.com/AgentRegistration.ReadWrite.All",
            "https://graph.microsoft.com/AgentRegistration.Read.All"
        });
    }, "Delegated Registry must request only the two documented AgentRegistration scopes.")
    .ValidateOnStart();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ProvisioningAdmissionGate>();
builder.Services.AddSingleton<DelegatedRegistryActionGate>();
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<Gateway.Domain.Interfaces.IAgent365DelegatedTokenProvider,
    MicrosoftIdentityWebDelegatedTokenProvider>();

builder.Services.AddApplicationServices();

builder.Services.AddInfrastructureServices(builder.Configuration);

builder.Services.AddAgent365Services(builder.Configuration);

builder.Services.AddPurviewServices(builder.Configuration);

builder.Services.AddGatewayObservability(builder.Configuration);

builder.Services.AddHttpClient();

builder.Services.AddControllers();

builder.Services.AddOpenApi();

builder.Services.AddHealthChecks()
    .AddDbContextCheck<GatewayDbContext>();

var app = builder.Build();

app.UseMiddleware<CorrelationIdMiddleware>();
app.UseMiddleware<ProblemDetailsMiddleware>();

app.MapOpenApi();
app.MapScalarApiReference();

app.UseAuthentication();
app.UseAuthorization();
app.UseMiddleware<IngressRateLimitMiddleware>();

app.MapControllers();
app.MapHealthChecks("/health/checks");

app.Run();

public partial class Program { }
