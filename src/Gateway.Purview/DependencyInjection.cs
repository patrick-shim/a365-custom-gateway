using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.Purview;

public static class DependencyInjection
{
    public static IServiceCollection AddPurviewServices(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.Configure<PurviewOptions>(
            configuration.GetSection(PurviewOptions.SectionName));

        services.AddMemoryCache();
        services.AddScoped<IPurviewPolicyClient, PurviewPolicyClient>();

        return services;
    }
}
