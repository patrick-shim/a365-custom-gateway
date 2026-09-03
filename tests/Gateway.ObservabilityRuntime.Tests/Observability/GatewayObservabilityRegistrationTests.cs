using System.Diagnostics;
using FluentAssertions;
using Gateway.Observability;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry;
using OpenTelemetry.Trace;

namespace Gateway.ObservabilityRuntime.Tests.Observability;

public sealed class GatewayObservabilityRegistrationTests
{
    private const string AzureSdkSourceName = "Azure.Messaging.ServiceBus";

    [Fact]
    public void Tracing_RecordsGatewaySpans_EvenWhenTheCallerSampledItselfOut()
    {
        using var provider = BuildTracerProvider(GatewayServiceNames.Api);

        using var activity = GatewayActivitySource.Instance.StartActivity(
            GatewayActivitySource.Operations.MirrorSanitizedTelemetry,
            ActivityKind.Internal,
            UnsampledCaller());

        activity.Should().NotBeNull(
            "an external agent that sampled itself out must not be able to suppress the gateway's own audit span");
        activity!.Recorded.Should().BeTrue();
    }

    [Fact]
    public void Tracing_SubscribesToAzureSdkSources()
    {
        using var provider = BuildTracerProvider(GatewayServiceNames.ProvisioningWorker);

        using var azureSdkSource = new ActivitySource(AzureSdkSourceName);
        using var activity = azureSdkSource.StartActivity("ServiceBusReceiver.Receive");

        activity.Should().NotBeNull(
            "Service Bus and Blob dependencies are only visible if the Azure SDK activity sources are subscribed");
        activity!.Recorded.Should().BeTrue();
    }

    [Fact]
    public void Tracing_TagsEachHostWithItsOwnServiceName()
    {
        using var apiProvider = BuildTracerProvider(GatewayServiceNames.Api);

        var attributes = apiProvider.GetResource().Attributes
            .ToDictionary(attribute => attribute.Key, attribute => attribute.Value, StringComparer.Ordinal);

        attributes.Should().ContainKey("service.name");
        attributes["service.name"].Should().Be(GatewayServiceNames.Api);
        attributes.Should().ContainKey("service.instance.id");
    }

    [Fact]
    public void ServiceNames_AreDistinctPerHostButShareTheGatewayPrefix()
    {
        GatewayServiceNames.Api.Should().NotBe(
            GatewayServiceNames.ProvisioningWorker,
            "API and provisioning worker telemetry were indistinguishable while both reported the same role name");

        GatewayServiceNames.Api.Should().StartWith(GatewayActivitySource.Name);
        GatewayServiceNames.ProvisioningWorker.Should().StartWith(GatewayActivitySource.Name);
    }

    [Fact]
    public void AddGatewayObservability_RejectsAMissingServiceName()
    {
        var services = new ServiceCollection();

        var act = () => services.AddGatewayObservability(EmptyConfiguration(), "  ");

        act.Should().Throw<ArgumentException>();
    }

    // A caller that arrives with sampled=0 on its traceparent. Under the default
    // parent-based sampler this drops the span outright, which is the loss this
    // registration is meant to prevent.
    private static ActivityContext UnsampledCaller()
    {
        return new ActivityContext(
            ActivityTraceId.CreateRandom(),
            ActivitySpanId.CreateRandom(),
            ActivityTraceFlags.None,
            isRemote: true);
    }

    private static TracerProvider BuildTracerProvider(string serviceName)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddGatewayObservability(EmptyConfiguration(), serviceName);

        var serviceProvider = services.BuildServiceProvider();
        return serviceProvider.GetRequiredService<TracerProvider>();
    }

    // No Application Insights connection string, so no exporter is registered and
    // the test never reaches the network.
    private static IConfiguration EmptyConfiguration()
    {
        return new ConfigurationBuilder().Build();
    }
}
