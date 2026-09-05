using Azure.Messaging.ServiceBus;
using FluentAssertions;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure;
using Gateway.Infrastructure.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.IntegrationTests.Services;

public sealed class ServiceBusRegistrationTests
{
    [Fact]
    public async Task ConnectionString_TakesPrecedence_WhenNamespaceIsAlsoConfigured()
    {
        await using var provider = BuildServiceProvider(
            connectionString: "Endpoint=sb://connection-path.servicebus.windows.net/;SharedAccessKeyName=test;SharedAccessKey=dGVzdA==",
            fullyQualifiedNamespace: "identity-path.servicebus.windows.net");

        var client = provider.GetRequiredService<ServiceBusClient>();

        client.FullyQualifiedNamespace.Should().Be("connection-path.servicebus.windows.net");
    }

    [Fact]
    public async Task FullyQualifiedNamespace_UsesCredentialPath_WhenConnectionStringIsBlank()
    {
        await using var provider = BuildServiceProvider(
            connectionString: "   ",
            fullyQualifiedNamespace: "identity-path.servicebus.windows.net");

        var client = provider.GetRequiredService<ServiceBusClient>();

        client.FullyQualifiedNamespace.Should().Be("identity-path.servicebus.windows.net");
    }

    [Fact]
    public async Task MissingConnectionStringAndNamespace_ThrowsClearConfigurationFailure()
    {
        await using var provider = BuildServiceProvider(
            connectionString: "   ",
            fullyQualifiedNamespace: "   ");

        var action = () => provider.GetRequiredService<ServiceBusClient>();

        action.Should()
            .Throw<InvalidOperationException>()
            .WithMessage("*ServiceBus:ConnectionString*ServiceBus:FullyQualifiedNamespace*");
    }

    [Fact]
    public async Task ProtectionPersistenceServices_AreRegisteredWithScopedLifetimes()
    {
        await using var provider = BuildServiceProvider(
            connectionString: "Endpoint=sb://connection-path.servicebus.windows.net/;SharedAccessKeyName=test;SharedAccessKey=dGVzdA==",
            fullyQualifiedNamespace: "");
        using var scope = provider.CreateScope();

        scope.ServiceProvider.GetRequiredService<IProtectionCapabilityRepository>()
            .Should().NotBeNull();
        scope.ServiceProvider.GetRequiredService<IPurviewTenantConnectionRepository>()
            .Should().NotBeNull();
        scope.ServiceProvider
            .GetRequiredService<IPurviewSensitiveInformationTypeSnapshotRepository>()
            .Should().NotBeNull();
        scope.ServiceProvider
            .GetRequiredService<IPurviewKnowYourDataConfigurationRepository>()
            .Should().NotBeNull();
        scope.ServiceProvider.GetRequiredService<IPurviewDlpProfileRepository>()
            .Should().NotBeNull();
        scope.ServiceProvider.GetRequiredService<IProtectionAdminOperationRepository>()
            .Should().NotBeNull();
        scope.ServiceProvider.GetRequiredService<IProtectionAdminOperationLockProvider>()
            .Should().NotBeNull();
    }

    private static ServiceProvider BuildServiceProvider(
        string? connectionString,
        string? fullyQualifiedNamespace)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:GatewayDb"] = "Server=(localdb)\\MSSQLLocalDB;Database=GatewayRegistrationTests;Trusted_Connection=True",
                ["BlobStorage:ConnectionString"] = "UseDevelopmentStorage=true",
                ["ServiceBus:ConnectionString"] = connectionString,
                ["ServiceBus:FullyQualifiedNamespace"] = fullyQualifiedNamespace,
                ["ServiceBus:QueueName"] = "gateway-provisioning-v3"
            })
            .Build();

        var services = new ServiceCollection();
        services.AddInfrastructureServices(configuration);
        return services.BuildServiceProvider();
    }
}
