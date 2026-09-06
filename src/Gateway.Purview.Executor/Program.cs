extern alias AzureIdentity;

using System.Text.Json;
using ManagedIdentityCredential = AzureIdentity::Azure.Identity.ManagedIdentityCredential;
using Azure.Storage.Blobs;
using Gateway.Provisioning.Worker;
using Gateway.Purview;
using Gateway.Purview.Executor;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
// No framework or provider body/exception logging in this certificate-owning host.
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(server => server.Limits.MaxRequestBodySize = 512 * 1024);
var hostOptions = builder.Configuration.GetSection(ExecutorHostOptions.SectionName)
    .Get<ExecutorHostOptions>() ?? throw new InvalidOperationException("Executor configuration is missing.");
var purviewOptions = builder.Configuration.GetSection(PurviewOptions.SectionName)
    .Get<PurviewOptions>() ?? throw new InvalidOperationException("Purview configuration is missing.");
// Deployment config supplies authority; requests cannot replace these bindings.
var binding = hostOptions.Binding ?? throw new InvalidOperationException("Executor binding is missing.");
purviewOptions.PolicyProvisioningPowerShellPath = Path.Combine(AppContext.BaseDirectory, "PowerShell", "pwsh.exe");
using (var startupDeadline = new CancellationTokenSource(TimeSpan.FromMinutes(3)))
    await ExecutorRuntimeAttestation.VerifyAsync(AppContext.BaseDirectory, hostOptions,
        purviewOptions, startupDeadline.Token);
if (!Uri.TryCreate(hostOptions.ClaimsContainerUri, UriKind.Absolute, out var claimsUri) ||
    claimsUri.Scheme != Uri.UriSchemeHttps || !claimsUri.IsDefaultPort ||
    !claimsUri.Host.EndsWith(".blob.core.windows.net", StringComparison.Ordinal) ||
    claimsUri.AbsolutePath != "/purview-executor-claims" ||
    !string.IsNullOrEmpty(claimsUri.Query + claimsUri.Fragment + claimsUri.UserInfo))
    throw new InvalidOperationException("Executor claim storage is invalid.");

builder.Services.AddSingleton(Options.Create(hostOptions));
builder.Services.AddSingleton(Options.Create(purviewOptions));
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<PurviewProcessSafety>();
builder.Services.AddSingleton<IExecutorClaimStore>(_ => new BlobExecutorClaimStore(
    new BlobContainerClient(claimsUri, new ManagedIdentityCredential(), new BlobClientOptions
    {
        Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(15) }
    })));
builder.Services.AddSingleton<ExecutorOperationJournal>();
builder.Services.AddSingleton<IPurviewConnectionVerificationProvider, PowerShellPurviewConnectionVerificationProvider>();
builder.Services.AddSingleton<IPurviewSettingsAutomation, PowerShellPurviewSettingsAutomation>();
builder.Services.AddSingleton<ExecutorDispatcher>();
builder.Services.AddSingleton(new SemaphoreSlim(1, 1));
var issuer = $"https://login.microsoftonline.com/{binding.TenantId:D}/v2.0";
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options =>
{
    options.Authority = issuer;
    options.Audience = binding.ExecutorApplicationId.ToString("D");
    options.MapInboundClaims = false;
    options.IncludeErrorDetails = false;
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidIssuer = issuer,
        ValidateAudience = true,
        ValidAudience = binding.ExecutorApplicationId.ToString("D"),
        ValidateLifetime = true,
        RequireExpirationTime = true,
        RequireSignedTokens = true,
        ValidateIssuerSigningKey = true,
        ClockSkew = TimeSpan.FromSeconds(30),
        RoleClaimType = "roles"
    };
});
builder.Services.AddAuthorization(options => options.AddPolicy("WorkerOnly", policy =>
    policy.RequireAuthenticatedUser().RequireAssertion(context =>
        ExecutorCallerAuthorization.IsAuthorized(context.User,
            new ExecutorCallerBinding(binding.TenantId, binding.GatewayWorkerPrincipalId,
                binding.CallerApplicationId)))));

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();
app.MapGet("/health/ready", (PurviewProcessSafety safety) =>
    safety.CanMutate ? Results.Ok(new
    {
        status = "Ready",
        binding.PackageDigest,
        binding.ExecutionSourceFingerprint
    }) : Results.StatusCode(503)).RequireAuthorization("WorkerOnly");
app.MapPost("/executor/v1/execute", async (HttpContext context, ExecutorDispatcher dispatcher,
    PurviewProcessSafety safety, SemaphoreSlim admission) =>
{
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
    deadline.CancelAfter(TimeSpan.FromSeconds(hostOptions.OperationTimeoutSeconds));
    var admitted = false;
    try
    {
        if (!context.Request.HasJsonContentType() || context.Request.ContentLength is > 512 * 1024)
            return Results.StatusCode(400);
        var request = await JsonSerializer.DeserializeAsync<PurviewExecutorRequest>(
            context.Request.Body, PurviewExecutorJson.Options, deadline.Token);
        if (request is null) return Results.StatusCode(400);
        // The deadline includes admission, Key Vault, provider execution and claim completion.
        await admission.WaitAsync(deadline.Token);
        admitted = true;
        if (!safety.CanMutate) return Results.StatusCode(503);
        var reply = await dispatcher.ExecuteAsync(request, deadline.Token);
        return Results.Json(reply, PurviewExecutorJson.Options);
    }
    catch (JsonException) { return Results.StatusCode(400); }
    catch (OperationCanceledException) { return Results.StatusCode(503); }
    catch (Exception) { return Results.StatusCode(503); }
    finally { if (admitted) admission.Release(); }
}).RequireAuthorization("WorkerOnly");
await app.RunAsync();
