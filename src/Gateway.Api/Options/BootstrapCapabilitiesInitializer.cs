using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Services;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class BootstrapCapabilitiesInitializer : IHostedService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IOptions<BootstrapCapabilitiesOptions> _options;
    private readonly IOptions<DatabaseAttestationOptions> _databaseAttestation;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<BootstrapCapabilitiesInitializer> _logger;
    private readonly IConfiguration? _configuration;

    public BootstrapCapabilitiesInitializer(
        IServiceScopeFactory scopeFactory,
        IOptions<BootstrapCapabilitiesOptions> options,
        IOptions<DatabaseAttestationOptions> databaseAttestation,
        TimeProvider timeProvider,
        ILogger<BootstrapCapabilitiesInitializer> logger,
        IConfiguration? configuration = null)
    {
        _scopeFactory = scopeFactory;
        _options = options;
        _databaseAttestation = databaseAttestation;
        _timeProvider = timeProvider;
        _logger = logger;
        _configuration = configuration;
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
        if (options.Preparation.IsConfigured)
        {
            var configuration = _configuration ?? throw new InvalidOperationException(
                "Capability preparation requires independently configured runtime identities.");
            var authorization = CapabilityPreparationContract.Authorize(options.Preparation, attestation,
                _timeProvider.GetUtcNow().UtcDateTime);
            var receipt = authorization.Receipt;
            if (!databaseAttestation.Enabled || !databaseAttestation.Upgrade.Enabled ||
                receipt.ApprovedPlanFingerprint != databaseAttestation.Upgrade.PlanFingerprint ||
                receipt.CandidateSourceFingerprint != databaseAttestation.Upgrade.UpgradeSourceFingerprint ||
                receipt.ApiPrincipal.ClientId != databaseAttestation.ApiPrincipalClientId ||
                receipt.WorkerPrincipal.ClientId != databaseAttestation.WorkerPrincipalClientId ||
                configuration["EntraId:TenantId"] != receipt.TenantId ||
                !string.IsNullOrEmpty(configuration["Agent365:TenantId"]) &&
                configuration["Agent365:TenantId"] != receipt.TenantId ||
                store is not ICapabilityPreparationStore preparedStore ||
                !await scope.ServiceProvider.GetRequiredService<IDatabaseBootstrapAttestationService>().AttestAsync(cancellationToken))
                throw new InvalidOperationException("Capability preparation requires the exact reviewed maintenance deployment and attested database/runtime bindings.");
            if (options.PromptShields.Status == "Installed" &&
                (!bool.TryParse(configuration["PromptShield:Enabled"], out var promptEnabled) || !promptEnabled ||
                 configuration["PromptShield:Endpoint"] != options.PromptShields.ContentSafetyEndpoint ||
                 !string.IsNullOrEmpty(configuration["PromptShield:ManagedIdentityClientId"]) &&
                 configuration["PromptShield:ManagedIdentityClientId"] != receipt.ApiPrincipal.ClientId))
                throw new InvalidOperationException("Prepared Prompt Shields facts do not match runtime configuration.");
            if (options.Purview.Status == "Installed" &&
                (!bool.TryParse(configuration["Purview:Enabled"], out var purviewEnabled) || !purviewEnabled ||
                 configuration["PurviewRuntimeIdentity:ManagedIdentityClientId"] != receipt.PurviewRuntimePrincipal!.ClientId ||
                 configuration["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] != receipt.PurviewRuntimePrincipal.ObjectId ||
                 !string.IsNullOrEmpty(configuration["Purview:ManagedIdentityClientId"]) &&
                 configuration["Purview:ManagedIdentityClientId"] != receipt.PurviewRuntimePrincipal.ClientId))
                throw new InvalidOperationException("Prepared Purview facts do not match runtime configuration.");
            await preparedStore.SynchronizePreparedAsync(attestation, authorization,
                _timeProvider.GetUtcNow().UtcDateTime, cancellationToken);
        }
        else
            await store.SynchronizeAsync(attestation, _timeProvider.GetUtcNow().UtcDateTime, cancellationToken);
        _logger.LogInformation(
            "Materialized bootstrap capability attestation for deployment ownership {DeploymentOwnershipId} and source {SourceFingerprint}",
            attestation.DeploymentOwnershipId,
            attestation.AcceptedSourceFingerprint);
    }

    public Task StopAsync(CancellationToken cancellationToken) =>
        Task.CompletedTask;
}
