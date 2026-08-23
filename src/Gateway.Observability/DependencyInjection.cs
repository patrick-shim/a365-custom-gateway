using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace Gateway.Observability;

public static class DependencyInjection
{
    public static IServiceCollection AddGatewayObservability(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        var options = new ObservabilityOptions();
        configuration.GetSection(ObservabilityOptions.SectionName).Bind(options);

        services.Configure<ObservabilityOptions>(
            configuration.GetSection(ObservabilityOptions.SectionName));

        services.AddOpenTelemetry()
            .WithTracing(builder =>
            {
                builder
                    .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(GatewayActivitySource.Name))
                    .AddSource(GatewayActivitySource.Name)
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddEntityFrameworkCoreInstrumentation()
                    .AddProcessor<RedactionProcessor>();

                if (!string.IsNullOrWhiteSpace(options.ApplicationInsightsConnectionString))
                {
                    builder.AddAzureMonitorTraceExporter(exporterOptions =>
                    {
                        exporterOptions.ConnectionString = options.ApplicationInsightsConnectionString;
                    });
                }
            });

        return services;
    }
}
