using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

public static class DependencyInjection
{
    public static IServiceCollection AddAgent365Services(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.Configure<Agent365Options>(
            configuration.GetSection(Agent365Options.SectionName));

        services.AddSingleton<IAgent365ProvisioningTokenProvider, WorkloadProvisioningTokenProvider>();
        services.AddHttpClient(nameof(Agent365ProvisioningClient), (serviceProvider, client) =>
        {
            var options = serviceProvider.GetRequiredService<IOptions<Agent365Options>>().Value;
            client.BaseAddress = MicrosoftGraphProvisioningClient.OfficialBaseAddress;
            client.Timeout = TimeSpan.FromSeconds(Math.Clamp(options.ProvisioningHttpTimeoutSeconds, 1, 120));
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
        {
            AllowAutoRedirect = false
        });
        services.AddScoped<IAgent365ProvisioningClient>(serviceProvider =>
            new Agent365ProvisioningClient(
                serviceProvider.GetRequiredService<ILogger<Agent365ProvisioningClient>>(),
                serviceProvider.GetRequiredService<IOptions<Agent365Options>>(),
                serviceProvider.GetRequiredService<IHttpClientFactory>(),
                serviceProvider.GetRequiredService<IAgent365ProvisioningTokenProvider>(),
                serviceProvider.GetRequiredService<IAgent365ObservabilityTokenProvider>()));
        services.AddScoped<IAgentPurviewAccessProvisioner>(sp => (Agent365ProvisioningClient)sp.GetRequiredService<IAgent365ProvisioningClient>());
        services.AddHttpClient(nameof(DelegatedAgent365RegistryClient), (serviceProvider, client) =>
        {
            var options = serviceProvider.GetRequiredService<IOptions<Agent365Options>>().Value;
            client.BaseAddress = MicrosoftGraphProvisioningClient.OfficialBaseAddress;
            client.Timeout = TimeSpan.FromSeconds(Math.Clamp(options.ProvisioningHttpTimeoutSeconds, 1, 120));
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
        {
            AllowAutoRedirect = false
        });
        services.AddScoped<IAgent365DelegatedRegistryClient>(serviceProvider =>
            new DelegatedAgent365RegistryClient(
                serviceProvider.GetRequiredService<IHttpClientFactory>(),
                serviceProvider.GetRequiredService<IAgent365DelegatedTokenProvider>(),
                serviceProvider.GetRequiredService<IOptions<Agent365Options>>()));
        services.AddScoped<IAgentIdentityBlueprintCatalog, AgentIdentityBlueprintCatalog>();
        services.AddHttpClient(nameof(AgentIdentityTokenProvider), (serviceProvider, client) =>
        {
            var options = serviceProvider.GetRequiredService<IOptions<Agent365Options>>().Value;
            client.Timeout = TimeSpan.FromSeconds(Math.Clamp(options.ObservabilityExportTimeoutSeconds, 1, 120));
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
        {
            AllowAutoRedirect = false
        });
        services.AddSingleton<AgentIdentityTokenProvider>();
        services.AddSingleton<IAgent365ObservabilityTokenProvider>(serviceProvider =>
            serviceProvider.GetRequiredService<AgentIdentityTokenProvider>());
        services.AddSingleton<IAgent365PurviewTokenProvider>(serviceProvider =>
            serviceProvider.GetRequiredService<AgentIdentityTokenProvider>());
        services.AddHttpClient(nameof(ObservabilityExporter), (serviceProvider, client) =>
        {
            var options = serviceProvider.GetRequiredService<IOptions<Agent365Options>>().Value;
            client.Timeout = TimeSpan.FromSeconds(Math.Clamp(options.ObservabilityExportTimeoutSeconds, 1, 120));
        });
        services.AddScoped<IObservabilityExporter, ObservabilityExporter>();

        return services;
    }
}
