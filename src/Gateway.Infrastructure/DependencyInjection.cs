using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using Gateway.Application.Configuration;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.Infrastructure.ServiceBus;
using Gateway.Infrastructure.Security;
using Gateway.Infrastructure.Services;
using Gateway.Infrastructure.Storage;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddInfrastructureServices(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddDbContext<GatewayDbContext>(options =>
            options.UseSqlServer(configuration.GetConnectionString("GatewayDb")));

        services.AddScoped<IAgentRepository, AgentRegistrationRepository>();
        services.AddScoped<IProvisioningJobRepository, ProvisioningJobRepository>();
        services.AddScoped<IActivityReceiptRepository, ActivityReceiptRepository>();
        services.AddScoped<IAiInteractionRepository, AiInteractionRepository>();
        services.AddScoped<IAuditEventRepository, AuditEventRepository>();
        services.AddScoped<IOutboxRepository, OutboxRepository>();
        services.AddScoped<IIdempotencyService, IdempotencyService>();
        services.AddScoped<IProvisioningExecutionLockProvider, ProvisioningExecutionLockProvider>();
        services.AddScoped<IUnitOfWork, UnitOfWork>();
        services.AddSingleton<IngressRateLimitProcessStore>();
        services.AddScoped<IIngressRateLimiter, SqlIngressRateLimiter>();
        services.AddScoped<ISystemConfigurationRepository, SystemConfigurationRepository>();
        services
            .AddOptions<AgentIngressCredentialOptions>()
            .Bind(configuration.GetSection(AgentIngressCredentialOptions.SectionName))
            .Validate(
                options => options.LifetimeDays is >= 1 and <= 3650,
                "AgentIngressCredentials:LifetimeDays must be between 1 and 3650.")
            .ValidateOnStart();
        services.AddScoped<IAgentIngressCredentialService, AgentIngressCredentialService>();

        services.Configure<BlobStorageOptions>(
            configuration.GetSection("BlobStorage"));

        services.AddSingleton(sp =>
        {
            var options = sp.GetRequiredService<IOptions<BlobStorageOptions>>().Value;
            if (!string.IsNullOrEmpty(options.ConnectionString))
                return new BlobServiceClient(options.ConnectionString);
            return new BlobServiceClient(
                new Uri(options.ServiceUri!),
                new DefaultAzureCredential());
        });

        services.AddScoped<IInteractionContentStore, BlobInteractionContentStore>();

        services.Configure<ServiceBusOptions>(
            configuration.GetSection("ServiceBus"));

        services.AddSingleton(sp =>
        {
            var options = sp.GetRequiredService<IOptions<ServiceBusOptions>>().Value;
            if (!string.IsNullOrWhiteSpace(options.ConnectionString))
                return new ServiceBusClient(options.ConnectionString);

            if (!string.IsNullOrWhiteSpace(options.FullyQualifiedNamespace))
            {
                return new ServiceBusClient(
                    options.FullyQualifiedNamespace,
                    new DefaultAzureCredential());
            }

            throw new InvalidOperationException(
                "Configure ServiceBus:ConnectionString for local development or " +
                "ServiceBus:FullyQualifiedNamespace for managed identity.");
        });

        services.AddSingleton(sp =>
        {
            var client = sp.GetRequiredService<ServiceBusClient>();
            var options = sp.GetRequiredService<IOptions<ServiceBusOptions>>().Value;
            return client.CreateSender(options.QueueName);
        });

        services.AddSingleton<IServiceBusPublisher, ServiceBusPublisher>();

        services.Configure<OutboxRelayOptions>(
            configuration.GetSection("OutboxRelay"));

        services.AddHostedService<OutboxRelayService>();

        return services;
    }
}
