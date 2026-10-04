using Amazon.Runtime;
using Amazon.S3;
using Gateway.Application.Configuration;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Messaging;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
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
        _ = InfrastructureProvider.Resolve(configuration);
        AddRuntimePersistence(services, configuration);

        services.AddMemoryCache();
        services.AddScoped<IDatabaseHealthProbe, DatabaseHealthProbe>();

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
        services.AddScoped<IPromptEvaluationRepository, PromptEvaluationRepository>();
        services.AddScoped<ISystemConfigurationMutationRepository, SystemConfigurationMutationRepository>();
        services.AddScoped<
            ISystemConfigurationLockProvider,
            SystemConfigurationLockProvider>();
        services
            .AddOptions<AgentIngressCredentialOptions>()
            .Bind(configuration.GetSection(AgentIngressCredentialOptions.SectionName))
            .Validate(
                options => options.LifetimeDays is >= 1 and <= 3650,
                "AgentIngressCredentials:LifetimeDays must be between 1 and 3650.")
            .ValidateOnStart();
        services.AddScoped<IAgentIngressCredentialService, AgentIngressCredentialService>();

        AddRuntimeMessagingAndStorage(services, configuration);

        services.Configure<OutboxRelayOptions>(
            configuration.GetSection("OutboxRelay"));
        services.AddHostedService<OutboxRelayService>();

        return services;
    }

    private static void AddRuntimePersistence(IServiceCollection services, IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("GatewayDb")
            ?? throw new InvalidOperationException(
                "Runtime infrastructure requires ConnectionStrings:GatewayDb (PostgreSQL).");

        services.AddDbContext<GatewayDbContext>(options =>
            options.UseNpgsql(connectionString)
                .AddInterceptors(new PostgresRowVersionInterceptor()));
        services.AddHostedService<RuntimeSchemaInitializer>();
    }

    private static void AddRuntimeMessagingAndStorage(
        IServiceCollection services,
        IConfiguration configuration)
    {
        services
            .AddOptions<ObjectStorageOptions>()
            .Bind(configuration.GetSection(ObjectStorageOptions.SectionName))
            .Validate(
                options =>
                    !string.IsNullOrWhiteSpace(options.ServiceUrl) &&
                    !string.IsNullOrWhiteSpace(options.AccessKey) &&
                    !string.IsNullOrWhiteSpace(options.SecretKey) &&
                    !string.IsNullOrWhiteSpace(options.BucketName),
                "ObjectStorage requires ServiceUrl, AccessKey, SecretKey, and BucketName.")
            .ValidateOnStart();

        services.AddSingleton<IAmazonS3>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<ObjectStorageOptions>>().Value;
            var config = new AmazonS3Config
            {
                ServiceURL = options.ServiceUrl,
                ForcePathStyle = options.ForcePathStyle,
                AuthenticationRegion = "us-east-1"
            };
            return new AmazonS3Client(
                new BasicAWSCredentials(options.AccessKey, options.SecretKey),
                config);
        });
        services.AddScoped<IInteractionContentStore, S3InteractionContentStore>();

        services
            .AddOptions<RabbitMqOptions>()
            .Bind(configuration.GetSection(RabbitMqOptions.SectionName))
            .Validate(
                options => !string.IsNullOrWhiteSpace(options.ConnectionUri),
                "RabbitMq:ConnectionUri is required for runtime infrastructure.")
            .ValidateOnStart();
        services.AddSingleton<IOutboxQueuePublisher, RabbitMqOutboxPublisher>();
    }
}
