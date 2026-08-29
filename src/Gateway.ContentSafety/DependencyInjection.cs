using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

public static class DependencyInjection
{
    public static IServiceCollection AddPromptShieldServices(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddOptions<PromptShieldOptions>()
            .Bind(configuration.GetSection(PromptShieldOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<PromptShieldOptions>, PromptShieldOptionsValidator>();
        services.AddSingleton<IPromptShieldTokenProvider, DefaultAzurePromptShieldTokenProvider>();
        services.AddHttpClient(nameof(PromptShieldClient), (serviceProvider, client) =>
        {
            var options = serviceProvider.GetRequiredService<IOptions<PromptShieldOptions>>().Value;
            client.BaseAddress = string.IsNullOrWhiteSpace(options.Endpoint)
                ? new Uri("https://localhost/")
                : new Uri(options.Endpoint.EndsWith("/", StringComparison.Ordinal)
                    ? options.Endpoint
                    : options.Endpoint + "/");
            client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
        }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
        services.AddSingleton<IPromptShieldClient>(serviceProvider =>
            new PromptShieldClient(
                serviceProvider.GetRequiredService<IHttpClientFactory>()
                    .CreateClient(nameof(PromptShieldClient)),
                serviceProvider.GetRequiredService<IPromptShieldTokenProvider>(),
                serviceProvider.GetRequiredService<IOptions<PromptShieldOptions>>()));

        return services;
    }
}
