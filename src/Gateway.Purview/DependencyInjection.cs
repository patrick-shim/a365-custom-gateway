using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

public static class DependencyInjection
{
    public static IServiceCollection AddPurviewServices(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddOptions<PurviewOptions>()
            .Bind(configuration.GetSection(PurviewOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<PurviewOptions>>(
            new PurviewOptionsValidator());

        services.AddMemoryCache();
        services.AddSingleton<IPurviewTokenProvider, DefaultAzurePurviewTokenProvider>();
        services.AddHttpClient(nameof(PurviewGraphClient), (serviceProvider, client) =>
        {
            var options = serviceProvider.GetRequiredService<IOptions<PurviewOptions>>().Value;
            client.BaseAddress = PurviewGraphClient.OfficialBaseAddress;
            client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
        {
            AllowAutoRedirect = false
        });
        services.AddSingleton<IPurviewGraphClient, PurviewGraphClient>();
        services.AddSingleton<IPurviewPolicyClient>(serviceProvider =>
            new PurviewPolicyClient(
                serviceProvider.GetRequiredService<ILogger<PurviewPolicyClient>>(),
                serviceProvider.GetRequiredService<IOptions<PurviewOptions>>(),
                serviceProvider.GetRequiredService<IMemoryCache>(),
                serviceProvider.GetRequiredService<IPurviewGraphClient>()));

        return services;
    }
}
