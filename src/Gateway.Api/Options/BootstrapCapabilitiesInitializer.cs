using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class BootstrapCapabilitiesInitializer : IHostedService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IOptions<BootstrapCapabilitiesOptions> _options;
    private readonly IOptions<DatabaseAttestationOptions> _databaseAttestation;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<BootstrapCapabilitiesInitializer> _logger;

    public BootstrapCapabilitiesInitializer(
        IServiceScopeFactory scopeFactory,
        IOptions<BootstrapCapabilitiesOptions> options,
        IOptions<DatabaseAttestationOptions> databaseAttestation,
        TimeProvider timeProvider,
        ILogger<BootstrapCapabilitiesInitializer> logger)
    {
        _scopeFactory = scopeFactory;
        _options = options;
        _databaseAttestation = databaseAttestation;
        _timeProvider = timeProvider;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var options = _options.Value;
        var databaseAttestation = _databaseAttestation.Value;
        if (!options.Enabled)
        {
            if (databaseAttestation.Enabled)
            {
                throw new InvalidOperationException(
                    "Bootstrap-managed API startup requires complete BootstrapCapabilities attestation.");
            }

            return;
        }
        if (databaseAttestation.Enabled &&
            (!string.Equals(
                options.DeploymentOwnershipId,
                databaseAttestation.DeploymentOwnershipId,
                StringComparison.Ordinal) ||
             !string.Equals(
                 options.AcceptedSourceFingerprint,
                 databaseAttestation.AcceptedSourceFingerprint,
                 StringComparison.Ordinal)))
        {
            throw new InvalidOperationException(
                "Bootstrap capability attestation does not match database deployment ownership and source.");
        }
        if (options.AttestedAtUtc >
            _timeProvider.GetUtcNow().AddMinutes(2))
        {
            throw new InvalidOperationException(
                "Bootstrap capability attestation timestamp is in the future.");
        }

        var attestation =
            BootstrapCapabilitiesOptionsValidator.CreateAttestation(
                options);
        await using var scope = _scopeFactory.CreateAsyncScope();
        var store = scope.ServiceProvider
            .GetRequiredService<IBootstrapProtectionCapabilityStore>();
        await store.SynchronizeAsync(
            attestation,
            _timeProvider.GetUtcNow().UtcDateTime,
            cancellationToken);
        _logger.LogInformation(
            "Materialized bootstrap capability attestation for deployment ownership {DeploymentOwnershipId} and source {SourceFingerprint}",
            attestation.DeploymentOwnershipId,
            attestation.AcceptedSourceFingerprint);
    }

    public Task StopAsync(CancellationToken cancellationToken) =>
        Task.CompletedTask;
}
