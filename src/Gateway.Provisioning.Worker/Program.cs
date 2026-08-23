using Azure.Messaging.ServiceBus;
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
builder.Services.AddGatewayObservability(builder.Configuration);

builder.Services.Configure<ProvisioningWorkerOptions>(
    builder.Configuration.GetSection("ProvisioningWorker"));

builder.Services.AddSingleton(sp =>
{
    var config = builder.Configuration;
    return new ServiceBusClient(config.GetConnectionString("ServiceBus")
        ?? config["ServiceBus:ConnectionString"]!);
});

builder.Services.AddScoped<ProvisioningMessageHandler>();
builder.Services.AddHostedService<ProvisioningWorkerService>();

var host = builder.Build();
host.Run();
