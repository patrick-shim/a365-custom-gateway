using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace Gateway.Observability;

public static class DependencyInjection
{
    public static IServiceCollection AddGatewayObservability(
        this IServiceCollection services,
        IConfiguration configuration,
        string serviceName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(serviceName);

        var options = new ObservabilityOptions();
        configuration.GetSection(ObservabilityOptions.SectionName).Bind(options);

        services.Configure<ObservabilityOptions>(
            configuration.GetSection(ObservabilityOptions.SectionName));

        // The container app replica hostname becomes AppRoleInstance, which is what
        // makes a single misbehaving replica identifiable in Application Insights.
        var resourceBuilder = ResourceBuilder.CreateDefault()
            .AddService(serviceName, serviceInstanceId: Environment.MachineName);

        var openTelemetry = services.AddOpenTelemetry();

        openTelemetry.WithTracing(builder =>
        {
            builder
                .SetResourceBuilder(resourceBuilder)
                // External agents call in with their own traceparent, and a caller
                // that sampled itself out would otherwise sample out the gateway's
                // own audit span with it. The sanitized mirror is a compliance
                // record rather than performance telemetry, so it is never a
                // candidate for sampling: record every span regardless of parent.
                .SetSampler(new AlwaysOnSampler())
                .AddSource(GatewayActivitySource.Name)
                // Service Bus and Blob calls are instrumented by the Azure SDK's own
                // activity sources. Without subscribing to them the provisioning
                // worker's queue and storage dependencies emit nothing at all.
                .AddSource("Azure.*")
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

        openTelemetry.WithMetrics(builder =>
        {
            builder
                .SetResourceBuilder(resourceBuilder)
                .AddMeter(GatewayObservabilityMetrics.MeterName);

            if (!string.IsNullOrWhiteSpace(options.ApplicationInsightsConnectionString))
            {
                builder.AddAzureMonitorMetricExporter(exporterOptions =>
                {
                    exporterOptions.ConnectionString = options.ApplicationInsightsConnectionString;
                });
            }
        });

        return services;
    }
}
