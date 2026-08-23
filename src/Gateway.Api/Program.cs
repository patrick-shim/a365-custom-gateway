using Gateway.Agent365;
using Gateway.Api.Authorization;
using Gateway.Api.Middleware;
using Gateway.Application;
using Gateway.Infrastructure;
using Gateway.Infrastructure.Persistence;
using Gateway.Observability;
using Gateway.Purview;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddMicrosoftIdentityWebApiAuthentication(builder.Configuration, "EntraId");

builder.Services.ConfigureAuthorizationPolicies();

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

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();
app.MapHealthChecks("/health/checks");

app.Run();

public partial class Program { }
