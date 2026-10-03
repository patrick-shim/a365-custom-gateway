using Gateway.Agent365;
using Gateway.Application;
using Gateway.Infrastructure;
using Gateway.Observability;
using Gateway.Provisioning.Worker;
using Gateway.Purview;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddApplicationServices();
builder.Services.AddInfrastructureServices(builder.Configuration);
builder.Services.AddAgent365Services(builder.Configuration);
builder.Services.AddPurviewServices(builder.Configuration);
builder.Services.AddGatewayObservability(
    builder.Configuration,
    GatewayServiceNames.ProvisioningWorker);

builder.Services.Configure<ProvisioningWorkerOptions>(
    builder.Configuration.GetSection("ProvisioningWorker"));

builder.Services.AddScoped<ProvisioningMessageHandler>();

if (InfrastructureProvider.IsPortable(builder.Configuration))
{
    builder.Services.Configure<ProtectionAdminWorkerOptions>(
        builder.Configuration.GetSection(ProtectionAdminWorkerOptions.SectionName));
    builder.Services.AddSingleton<
        IPurviewConnectionVerificationProvider,
        RemotePurviewConnectionVerificationProvider>();
    builder.Services.AddScoped<IPurviewRuntimeReadinessValidator, PurviewRuntimeReadinessValidator>();
    builder.Services.AddScoped<ProtectionAdminMessageHandler>();
    builder.Services.AddHostedService<RabbitMqProvisioningWorkerService>();
    builder.Services.AddHostedService<RabbitMqProtectionAdminWorkerService>();
}
else
{
    builder.Services.AddHostedService<ProvisioningWorkerService>();
    builder.Services.AddProtectionAdministrationWorker(builder.Configuration);
}

var host = builder.Build();
host.Run();
