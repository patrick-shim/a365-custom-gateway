using System.Data;
using System.Security.Cryptography;
using System.Text;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Gateway.Infrastructure.Services;

internal sealed class BootstrapProtectionCapabilityStore
    : IBootstrapProtectionCapabilityStore
{
    private const string SqlServerProviderName =
        "Microsoft.EntityFrameworkCore.SqlServer";
    private const string InMemoryProviderName =
        "Microsoft.EntityFrameworkCore.InMemory";
    private const string LockResource =
        "a365gw:bootstrap-protection-capabilities:v1";
    private static readonly SemaphoreSlim InMemoryLock = new(1, 1);
    private readonly Persistence.GatewayDbContext _dbContext;

    public BootstrapProtectionCapabilityStore(
        Persistence.GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task SynchronizeAsync(
        BootstrapProtectionCapabilityAttestation attestation,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        Validate(attestation, utcNow);
        var provider = _dbContext.Database.ProviderName;
        if (string.Equals(
                provider,
                InMemoryProviderName,
                StringComparison.Ordinal))
        {
            await InMemoryLock.WaitAsync(cancellationToken);
            try
            {
                await SynchronizeCoreAsync(
                    attestation,
                    utcNow,
                    cancellationToken);
            }
            finally
            {
                InMemoryLock.Release();
            }

            return;
        }

        if (!string.Equals(
                provider,
                SqlServerProviderName,
                StringComparison.Ordinal))
        {
            throw new NotSupportedException(
                $"Bootstrap capability synchronization is not supported by EF provider '{provider ?? "unknown"}'.");
        }

        if (_dbContext.Database.CurrentTransaction is not null)
        {
            throw new InvalidOperationException(
                "Bootstrap capability synchronization must own its SQL transaction.");
        }

        await using var transaction =
            await _dbContext.Database.BeginTransactionAsync(
                IsolationLevel.Serializable,
                cancellationToken);
        try
        {
            await AcquireSqlLockAsync(transaction, cancellationToken);
            await SynchronizeCoreAsync(
                attestation,
                utcNow,
                cancellationToken);
            await transaction.CommitAsync(cancellationToken);
        }
        catch
        {
            await transaction.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private async Task SynchronizeCoreAsync(
        BootstrapProtectionCapabilityAttestation attestation,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        var existing = await _dbContext.ProtectionCapabilities
            .OrderBy(capability => capability.Kind)
            .ToArrayAsync(cancellationToken);
        if (existing.Length is not 0 and not 3)
        {
            throw new InvalidOperationException(
                "Protection capability persistence is partial and cannot be adopted.");
        }

        var byKind = existing.ToDictionary(capability => capability.Kind);
        var changed = false;
        foreach (var fact in attestation.Capabilities
                     .OrderBy(fact => fact.Kind))
        {
            var deterministicId = CreateDeterministicId(
                attestation.DeploymentOwnershipId,
                fact.Kind);
            if (!byKind.TryGetValue(fact.Kind, out var capability))
            {
                capability = new ProtectionCapability
                {
                    Id = deterministicId,
                    Kind = fact.Kind,
                    Status = fact.Status,
                    ResourceIdentifiers = fact.ResourceIdentifiers,
                    LastReadbackAtUtc = attestation.AttestedAtUtc,
                    LastFailureCode = null,
                    CreatedAtUtc = utcNow,
                    UpdatedAtUtc = utcNow
                };
                await _dbContext.ProtectionCapabilities.AddAsync(
                    capability,
                    cancellationToken);
                changed = true;
                continue;
            }

            EnsureBinding(
                capability,
                deterministicId,
                attestation);
            if (capability.Status != fact.Status)
            {
                throw new InvalidOperationException(
                    $"Persisted {fact.Kind} capability status drifted from bootstrap attestation.");
            }

            if (fact.Status == ProtectionCapabilityStatus.Installed)
            {
                if (!IdentifiersEqual(
                        capability.ResourceIdentifiers,
                        fact.ResourceIdentifiers) ||
                    capability.LastReadbackAtUtc !=
                        attestation.AttestedAtUtc ||
                    capability.LastFailureCode is not null)
                {
                    throw new InvalidOperationException(
                        $"Persisted {fact.Kind} installed capability facts drifted from bootstrap attestation.");
                }

                continue;
            }

            if (!IdentifiersEqual(
                    capability.ResourceIdentifiers,
                    fact.ResourceIdentifiers) ||
                capability.LastReadbackAtUtc !=
                    attestation.AttestedAtUtc ||
                capability.LastFailureCode is not null)
            {
                capability.ResourceIdentifiers =
                    fact.ResourceIdentifiers;
                capability.LastReadbackAtUtc =
                    attestation.AttestedAtUtc;
                capability.LastFailureCode = null;
                capability.UpdatedAtUtc = utcNow;
                changed = true;
            }
        }

        if (changed)
            await _dbContext.SaveChangesAsync(cancellationToken);
    }

    private static void EnsureBinding(
        ProtectionCapability capability,
        Guid deterministicId,
        BootstrapProtectionCapabilityAttestation attestation)
    {
        if (capability.Id != deterministicId ||
            capability.ResourceIdentifiers
                .BootstrapDeploymentOwnershipId !=
                attestation.DeploymentOwnershipId ||
            !string.Equals(
                capability.ResourceIdentifiers
                    .BootstrapSourceFingerprint,
                attestation.AcceptedSourceFingerprint,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Persisted protection capabilities belong to a different deployment or source.");
        }
    }

    private static bool IdentifiersEqual(
            ProtectionCapabilityResourceIdentifiers first,
            ProtectionCapabilityResourceIdentifiers second) =>
            first.Agent365RegistryApiApplicationId ==
                second.Agent365RegistryApiApplicationId &&
            string.Equals(
                first.ContentSafetyAccountResourceId,
                second.ContentSafetyAccountResourceId,
                StringComparison.Ordinal) &&
            string.Equals(
                first.ContentSafetyEndpoint,
                second.ContentSafetyEndpoint,
                StringComparison.Ordinal) &&
            first.GatewayApiManagedIdentityPrincipalObjectId ==
                second.GatewayApiManagedIdentityPrincipalObjectId &&
            first.PurviewRuntimeManagedIdentityPrincipalObjectId ==
                second.PurviewRuntimeManagedIdentityPrincipalObjectId &&
            first.PurviewAutomationApplicationId ==
                second.PurviewAutomationApplicationId &&
            first.PurviewAutomationServicePrincipalObjectId ==
                second.PurviewAutomationServicePrincipalObjectId &&
            string.Equals(
                first.KeyVaultResourceId,
                second.KeyVaultResourceId,
                StringComparison.Ordinal) &&
            string.Equals(
                first.CertificateName,
                second.CertificateName,
                StringComparison.Ordinal) &&
            first.BootstrapDeploymentOwnershipId ==
                second.BootstrapDeploymentOwnershipId &&
            string.Equals(
                first.BootstrapSourceFingerprint,
                second.BootstrapSourceFingerprint,
                StringComparison.Ordinal) &&
            string.Equals(
                first.KeyVaultHost,
                second.KeyVaultHost,
                StringComparison.Ordinal) &&
            string.Equals(
                first.CertificateSecretUri,
                second.CertificateSecretUri,
                StringComparison.Ordinal);

    private static void Validate(
        BootstrapProtectionCapabilityAttestation attestation,
        DateTime utcNow)
    {
        ArgumentNullException.ThrowIfNull(attestation);
        if (attestation.DeploymentOwnershipId == Guid.Empty ||
            string.IsNullOrWhiteSpace(
                attestation.AcceptedSourceFingerprint) ||
            attestation.AttestedAtUtc.Kind != DateTimeKind.Utc ||
            utcNow.Kind != DateTimeKind.Utc ||
            attestation.Capabilities.Count != 3 ||
            attestation.Capabilities
                .Select(fact => fact.Kind)
                .Distinct()
                .Count() != 3 ||
            !attestation.Capabilities
                .Select(fact => fact.Kind)
                .OrderBy(kind => kind)
                .SequenceEqual(Enum.GetValues<ProtectionCapabilityKind>()) ||
            attestation.Capabilities.Any(fact =>
                fact.Status is not ProtectionCapabilityStatus.Installed and
                    not ProtectionCapabilityStatus.NotInstalled ||
                fact.ResourceIdentifiers
                    .BootstrapDeploymentOwnershipId !=
                    attestation.DeploymentOwnershipId ||
                !string.Equals(
                    fact.ResourceIdentifiers
                        .BootstrapSourceFingerprint,
                    attestation.AcceptedSourceFingerprint,
                    StringComparison.Ordinal)))
        {
            throw new InvalidOperationException(
                "Bootstrap capability attestation is incomplete or invalid.");
        }
    }

    private async Task AcquireSqlLockAsync(
        IDbContextTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command =
            _dbContext.Database.GetDbConnection().CreateCommand();
        command.Transaction = transaction.GetDbTransaction();
        command.CommandTimeout = 35;
        command.CommandText =
            "DECLARE @result int; " +
            "EXEC @result = sys.sp_getapplock " +
            "@Resource = @resource, @LockMode = 'Exclusive', " +
            "@LockOwner = 'Transaction', @LockTimeout = 30000; " +
            "SELECT @result;";
        var parameter = command.CreateParameter();
        parameter.ParameterName = "@resource";
        parameter.DbType = DbType.String;
        parameter.Size = 255;
        parameter.Value = LockResource;
        command.Parameters.Add(parameter);
        var result = Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken));
        if (result < 0)
        {
            throw new TimeoutException(
                "Bootstrap capability synchronization could not acquire its SQL lock.");
        }
    }

    internal static Guid CreateDeterministicId(
        Guid deploymentOwnershipId,
        ProtectionCapabilityKind kind)
    {
        var material = Encoding.UTF8.GetBytes(
            $"{deploymentOwnershipId:D}\n{kind}");
        try
        {
            var bytes = SHA256.HashData(material)[..16];
            bytes[6] = (byte)((bytes[6] & 0x0f) | 0x50);
            bytes[8] = (byte)((bytes[8] & 0x3f) | 0x80);
            return new Guid(bytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(material);
        }
    }
}
