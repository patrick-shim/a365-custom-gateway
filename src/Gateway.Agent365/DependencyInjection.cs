using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.Agent365;

public static class DependencyInjection
{
    public static IServiceCollection AddAgent365Services(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.Configure<Agent365Options>(
            configuration.GetSection(Agent365Options.SectionName));

        services.AddScoped<IAgent365ProvisioningClient, Agent365ProvisioningClient>();
        services.AddScoped<IObservabilityExporter, ObservabilityExporter>();

        return services;
    }
}
