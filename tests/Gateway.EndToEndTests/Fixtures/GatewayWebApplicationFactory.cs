using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using NSubstitute;

namespace Gateway.EndToEndTests.Fixtures;

public class GatewayWebApplicationFactory : WebApplicationFactory<Program>
{
    private readonly string _databaseName = $"TestDb_{Guid.NewGuid()}";

    public IInteractionContentStore MockContentStore { get; } = Substitute.For<IInteractionContentStore>();
    public IAgent365ProvisioningClient MockProvisioningClient { get; } = Substitute.For<IAgent365ProvisioningClient>();
    public IPurviewPolicyClient MockPurviewClient { get; } = Substitute.For<IPurviewPolicyClient>();
    public IObservabilityExporter MockObservabilityExporter { get; } = Substitute.For<IObservabilityExporter>();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");

        builder.ConfigureAppConfiguration((context, config) =>
        {
            config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["EntraId:Instance"] = "https://login.microsoftonline.com/",
                ["EntraId:TenantId"] = "test-tenant-id",
                ["EntraId:ClientId"] = "test-client-id",
                ["BlobStorage:ConnectionString"] = "UseDevelopmentStorage=true",
                ["ServiceBus:ConnectionString"] = "Endpoint=sb://test.servicebus.windows.net/;SharedAccessKeyName=test;SharedAccessKey=dGVzdA==",
                ["ServiceBus:QueueName"] = "test-queue",
                ["OutboxRelay:PollingIntervalSeconds"] = "3600",
                ["OutboxRelay:BatchSize"] = "10",
                ["Observability:ApplicationInsightsConnectionString"] = "",
            });
        });

        builder.ConfigureTestServices(services =>
        {
            // Remove the real GatewayDbContext registration
            services.RemoveAll<DbContextOptions<GatewayDbContext>>();
            services.RemoveAll<GatewayDbContext>();

            // Remove all DbContext options
            var dbContextDescriptors = services
                .Where(d => d.ServiceType.IsGenericType &&
                            d.ServiceType.GetGenericTypeDefinition() == typeof(DbContextOptions<>))
                .ToList();
            foreach (var descriptor in dbContextDescriptors)
                services.Remove(descriptor);

            // Add InMemory GatewayDbContext
            services.AddDbContext<GatewayDbContext>(options =>
            {
                options.UseInMemoryDatabase(_databaseName);
                options.EnableServiceProviderCaching(false);
            });

            // Remove hosted services from Infrastructure (OutboxRelayService)
            var hostedServiceDescriptors = services
                .Where(d => d.ServiceType == typeof(IHostedService) &&
                            d.ImplementationType?.Assembly == typeof(GatewayDbContext).Assembly)
                .ToList();
            foreach (var descriptor in hostedServiceDescriptors)
                services.Remove(descriptor);

            // Remove Azure SDK singletons that require real connections
            services.RemoveAll<Azure.Messaging.ServiceBus.ServiceBusClient>();
            services.RemoveAll<Azure.Messaging.ServiceBus.ServiceBusSender>();
            services.RemoveAll<Azure.Storage.Blobs.BlobServiceClient>();

            // Remove and replace internal IServiceBusPublisher
            var serviceBusPublisherDescriptor = services
                .FirstOrDefault(d => d.ServiceType == typeof(IServiceBusPublisher));
            if (serviceBusPublisherDescriptor != null)
                services.Remove(serviceBusPublisherDescriptor);

            var mockPublisher = Substitute.For<IServiceBusPublisher>();
            services.AddSingleton(mockPublisher);

            // Replace external service implementations with mocks
            services.RemoveAll<IInteractionContentStore>();
            services.AddScoped(_ => MockContentStore);

            services.RemoveAll<IAgent365ProvisioningClient>();
            services.AddScoped(_ => MockProvisioningClient);

            services.RemoveAll<IPurviewPolicyClient>();
            services.AddScoped(_ => MockPurviewClient);

            services.RemoveAll<IObservabilityExporter>();
            services.AddScoped(_ => MockObservabilityExporter);

            // Replace authentication with test scheme
            services.AddAuthentication(options =>
            {
                options.DefaultAuthenticateScheme = TestAuthHandler.SchemeName;
                options.DefaultChallengeScheme = TestAuthHandler.SchemeName;
                options.DefaultScheme = TestAuthHandler.SchemeName;
            })
            .AddScheme<AuthenticationSchemeOptions, TestAuthHandler>(
                TestAuthHandler.SchemeName, _ => { });
        });
    }

    /// <summary>
    /// Gets the GatewayDbContext from the service provider for direct DB manipulation in tests.
    /// </summary>
    public GatewayDbContext GetDbContext()
    {
        var scope = Services.CreateScope();
        return scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
    }

    /// <summary>
    /// Creates a new HttpClient and resets the auth handler to default state.
    /// </summary>
    public HttpClient CreateAuthenticatedClient()
    {
        TestAuthHandler.Reset();
        return CreateClient();
    }
}
