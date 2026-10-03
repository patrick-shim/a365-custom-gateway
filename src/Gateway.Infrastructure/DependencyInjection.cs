using Amazon.Runtime;
using Amazon.S3;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using Gateway.Application.Configuration;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Messaging;
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
        var provider = InfrastructureProvider.Resolve(configuration);
        if (provider == InfrastructureProvider.Portable)
            AddPortablePersistence(services, configuration);
        else
            AddAzurePersistence(services, configuration);

        services.AddMemoryCache();
        services
            .AddOptions<DatabaseAttestationOptions>()
            .Bind(configuration.GetSection(DatabaseAttestationOptions.SectionName));
        services.AddSingleton<IValidateOptions<DatabaseAttestationOptions>, DatabaseAttestationOptionsValidator>();
        services.AddScoped<IDatabaseHealthProbe, DatabaseHealthProbe>();
        services.AddScoped<IDatabaseBootstrapAttestationProbe, DatabaseBootstrapAttestationProbe>();
        services.AddScoped<IDatabaseBootstrapAttestationService, DatabaseBootstrapAttestationService>();

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
        services.AddScoped<IPurviewPolicyProfileRepository, PurviewPolicyProfileRepository>();
        services.AddScoped<IPromptEvaluationRepository, PromptEvaluationRepository>();
        services.AddScoped<IProtectionCapabilityRepository, ProtectionCapabilityRepository>();
        services.AddScoped<
            IBootstrapProtectionCapabilityStore,
            BootstrapProtectionCapabilityStore>();
        services.AddScoped<IPurviewTenantConnectionRepository, PurviewTenantConnectionRepository>();
        services.AddScoped<
            IPurviewSensitiveInformationTypeSnapshotRepository,
            PurviewSensitiveInformationTypeSnapshotRepository>();
        services.AddScoped<
            IPurviewKnowYourDataConfigurationRepository,
            PurviewKnowYourDataConfigurationRepository>();
        services.AddScoped<IPurviewDlpProfileRepository, PurviewDlpProfileRepository>();
        services.AddScoped<IProtectionAdminOperationRepository, ProtectionAdminOperationRepository>();
        services.AddScoped<IPurviewRuntimeTestRepository, PurviewRuntimeTestRepository>();
        services.AddScoped<IProtectionProfileMutationGuard, ProtectionProfileMutationGuard>();
        services.AddScoped<
            IProtectionAdminOperationLockProvider,
            ProtectionAdminOperationLockProvider>();
        services
            .AddOptions<AgentIngressCredentialOptions>()
            .Bind(configuration.GetSection(AgentIngressCredentialOptions.SectionName))
            .Validate(
                options => options.LifetimeDays is >= 1 and <= 3650,
                "AgentIngressCredentials:LifetimeDays must be between 1 and 3650.")
            .ValidateOnStart();
        services.AddScoped<IAgentIngressCredentialService, AgentIngressCredentialService>();

        if (provider == InfrastructureProvider.Portable)
            AddPortableMessagingAndStorage(services, configuration);
        else
            AddAzureMessagingAndStorage(services, configuration);

        services.Configure<OutboxRelayOptions>(
            configuration.GetSection("OutboxRelay"));
        services.AddHostedService<OutboxRelayService>();

        return services;
    }

    private static void AddAzurePersistence(IServiceCollection services, IConfiguration configuration)
    {
        services.AddDbContext<GatewayDbContext>(options =>
            options.UseSqlServer(configuration.GetConnectionString("GatewayDb")));
    }

    private static void AddPortablePersistence(IServiceCollection services, IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("GatewayDb")
            ?? throw new InvalidOperationException(
                "Portable infrastructure requires ConnectionStrings:GatewayDb (PostgreSQL).");

        services.AddDbContext<GatewayDbContext>(options =>
            options.UseNpgsql(connectionString)
                .AddInterceptors(new PostgresRowVersionInterceptor()));
        services.AddHostedService<PortableSchemaInitializer>();
    }

    private static void AddAzureMessagingAndStorage(
        IServiceCollection services,
        IConfiguration configuration)
    {
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

        services.AddSingleton<IOutboxQueuePublisher, ServiceBusPublisher>();
    }

    private static void AddPortableMessagingAndStorage(
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
                "RabbitMq:ConnectionUri is required for portable infrastructure.")
            .ValidateOnStart();
        services.AddSingleton<IOutboxQueuePublisher, RabbitMqOutboxPublisher>();
    }
}
