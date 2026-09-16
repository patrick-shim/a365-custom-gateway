using Gateway.Api.Options;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Persistence;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Infrastructure;

public sealed class MaintenanceCutoverStartup(
    IServiceScopeFactory scopeFactory,
    MaintenanceCutoverOptions maintenance,
    IOptions<DatabaseAttestationOptions> databaseOptions) : IHostedService
{
    public static void HoldOperationalServices(IServiceCollection services)
    {
        var relays = services.Where(descriptor =>
            descriptor.ServiceType == typeof(IHostedService) &&
            descriptor.ImplementationType?.Assembly == typeof(OutboxRelayOptions).Assembly &&
            descriptor.ImplementationType.FullName == "Gateway.Infrastructure.Outbox.OutboxRelayService").ToArray();
        if (relays.Length != 1)
            throw new InvalidOperationException("Maintenance requires exactly one known operational relay registration to hold.");
        services.Remove(relays[0]);
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var database = databaseOptions.Value;
        if (maintenance.Phase != MaintenanceCutoverPhase.PostSchemaClosed ||
            !database.Enabled || !database.Upgrade.Enabled ||
            database.Upgrade.PlanFingerprint != maintenance.PlanFingerprint ||
            database.Upgrade.UpgradeSourceFingerprint != maintenance.CandidateSourceFingerprint)
            throw new InvalidOperationException(
                "Post-schema maintenance requires matching enabled database upgrade attestation.");

        await using var scope = scopeFactory.CreateAsyncScope();
        if (!await scope.ServiceProvider.GetRequiredService<IDatabaseBootstrapAttestationService>()
                .AttestAsync(cancellationToken))
            throw new InvalidOperationException("Post-schema maintenance database attestation did not pass.");
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
