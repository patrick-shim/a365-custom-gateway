using System.Data;
using System.Security.Cryptography;
using System.Text;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Gateway.Infrastructure.Services;

internal sealed class BootstrapProtectionCapabilityStore
    : IBootstrapProtectionCapabilityStore, ICapabilityPreparationStore
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

    public Task SynchronizeAsync(
        BootstrapProtectionCapabilityAttestation attestation,
        DateTime utcNow,
        CancellationToken cancellationToken) =>
        SynchronizeOwnedAsync(attestation, null, utcNow, cancellationToken);

    public Task SynchronizePreparedAsync(BootstrapProtectionCapabilityAttestation target,
        CapabilityPreparationAuthorization authorization, DateTime utcNow, CancellationToken cancellationToken) =>
        SynchronizeOwnedAsync(target, authorization, utcNow, cancellationToken);

    private async Task SynchronizeOwnedAsync(BootstrapProtectionCapabilityAttestation attestation,
        CapabilityPreparationAuthorization? authorization, DateTime utcNow, CancellationToken cancellationToken)
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
                    authorization,
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
                authorization,
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
        CapabilityPreparationAuthorization? authorization,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        var existing = await _dbContext.ProtectionCapabilities
            .OrderBy(capability => capability.Kind)
            .ToArrayAsync(cancellationToken);
        foreach (var capability in existing)
            await _dbContext.Entry(capability).ReloadAsync(cancellationToken);
        if (authorization is not null)
        {
            await ApplyPreparationAsync(attestation, authorization, existing, utcNow, cancellationToken);
            return;
        }
        if (await _dbContext.Set<CapabilityPreparationHistory>().AnyAsync(
                value => value.DeploymentOwnershipId == attestation.DeploymentOwnershipId, cancellationToken))
            throw new InvalidOperationException("Capability preparation receipt is required to verify an upgraded projection; legacy configuration cannot bypass its history.");
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

    private async Task ApplyPreparationAsync(BootstrapProtectionCapabilityAttestation target,
        CapabilityPreparationAuthorization authorization, ProtectionCapability[] existing,
        DateTime utcNow, CancellationToken cancellationToken)
    {
        var receipt = authorization.Receipt;
        CapabilityPreparationContract.Validate(receipt, target, utcNow);
        CapabilityPreparationContract.Require(
            CapabilityPreparationContract.Serialize(receipt) == authorization.ReceiptJson &&
            DatabaseUpgradeAttestation.Fingerprint(authorization.ReceiptJson) == authorization.ReceiptFingerprint,
            "Prepared receipt changed after authorization.");
        CapabilityPreparationContract.Require(existing.Length == 3 && existing.All(value =>
            value.LastReadbackAtUtc is not null && value.LastFailureCode is null) &&
            existing.Select(value => value.LastReadbackAtUtc).Distinct().Count() == 1,
            "Original persisted capability facts are missing, partial or unverified.");
        foreach (var capability in existing)
            EnsureBinding(capability, CreateDeterministicId(target.DeploymentOwnershipId, capability.Kind), target);
        var actual = new BootstrapProtectionCapabilityAttestation(target.DeploymentOwnershipId, target.AcceptedSourceFingerprint,
            existing[0].LastReadbackAtUtc!.Value, existing.Select(value =>
                new BootstrapProtectionCapabilityFact(value.Kind, value.Status, value.ResourceIdentifiers)).ToArray());
        var actualJson = CapabilityPreparationContract.FactsJson(actual);
        var targetJson = CapabilityPreparationContract.FactsJson(target);
        var history = await _dbContext.Set<CapabilityPreparationHistory>().AsNoTracking()
            .Where(value => value.DeploymentOwnershipId == target.DeploymentOwnershipId)
            .ToArrayAsync(cancellationToken);
        foreach (var entry in history)
        {
            var historicalReceipt = CapabilityPreparationContract.Parse(entry.ReceiptJson);
            CapabilityPreparationContract.Require(DatabaseUpgradeAttestation.Fingerprint(entry.ReceiptJson) == entry.ReceiptFingerprint,
                "Persisted preparation history was modified.");
            CapabilityPreparationContract.Require(entry.Id.ToString("D") == historicalReceipt.UpgradeId &&
                entry.ApprovedPlanFingerprint == historicalReceipt.ApprovedPlanFingerprint &&
                entry.DeploymentOwnershipId.ToString("D") == historicalReceipt.DeploymentOwnershipId &&
                entry.PreviousReceiptFingerprint == historicalReceipt.PreviousReceiptFingerprint &&
                entry.OriginalCapabilityFactsHash == historicalReceipt.OriginalCapabilityFactsHash &&
                DatabaseUpgradeAttestation.Fingerprint(entry.PriorCapabilityFactsJson) == historicalReceipt.ExpectedPriorCapabilityFactsHash &&
                entry.TargetCapabilityFactsJson == CapabilityPreparationContract.TargetFactsJson(historicalReceipt),
                "Persisted preparation history facts changed.");
        }
        CapabilityPreparationHistory? historyHead = null;
        if (history.Length != 0)
        {
            var roots = history.Where(value => value.PreviousReceiptFingerprint is null).ToArray();
            CapabilityPreparationContract.Require(history.Length <= 2 && roots.Length == 1 &&
                history.Select(value => value.OriginalCapabilityFactsHash).Distinct().Count() == 1,
                "Preparation history is partial or contains foreign branches.");
            var visited = new HashSet<string>(StringComparer.Ordinal);
            CapabilityPreparationHistory? cursor = roots[0];
            while (cursor is not null && visited.Add(cursor.ReceiptFingerprint))
            {
                var children = history.Where(value => value.PreviousReceiptFingerprint == cursor.ReceiptFingerprint).ToArray();
                CapabilityPreparationContract.Require(children.Length <= 1, "Conflicting preparation history branches.");
                cursor = children.SingleOrDefault();
            }
            CapabilityPreparationContract.Require(visited.Count == history.Length, "Preparation history chain is incomplete.");
            var heads = history.Where(value => !history.Any(child =>
                child.PreviousReceiptFingerprint == value.ReceiptFingerprint)).ToArray();
            CapabilityPreparationContract.Require(heads.Length == 1, "Preparation history has no unique latest head.");
            historyHead = heads[0];
            CapabilityPreparationContract.Require(actualJson == historyHead.TargetCapabilityFactsJson,
                "Effective capability projection does not match the latest preparation history head.");
        }
        var replay = history.SingleOrDefault(value => value.Id == Guid.Parse(receipt.UpgradeId));
        if (replay is not null)
        {
            CapabilityPreparationContract.Require(replay.Id == historyHead?.Id &&
                replay.ReceiptJson == authorization.ReceiptJson &&
                replay.ReceiptFingerprint == authorization.ReceiptFingerprint &&
                replay.TargetCapabilityFactsJson == targetJson && actualJson == targetJson &&
                DatabaseUpgradeAttestation.Fingerprint(replay.PriorCapabilityFactsJson) == receipt.ExpectedPriorCapabilityFactsHash &&
                replay.OriginalCapabilityFactsHash == receipt.OriginalCapabilityFactsHash &&
                replay.PreviousReceiptFingerprint == receipt.PreviousReceiptFingerprint,
                "Conflicting receipt replay or changed effective capability projection.");
            return;
        }
        CapabilityPreparationContract.Require(history.All(value => value.ApprovedPlanFingerprint != receipt.ApprovedPlanFingerprint) &&
            DatabaseUpgradeAttestation.Fingerprint(actualJson) == receipt.ExpectedPriorCapabilityFactsHash,
            "Receipt plan was already consumed or expected prior facts changed.");
        CapabilityPreparationContract.Require(target.AttestedAtUtc > actual.AttestedAtUtc,
            "Prepared readback must be newer than the prior capability facts.");
        CapabilityPreparationContract.Require(!await _dbContext.Set<CapabilityPreparationHistory>().AnyAsync(value =>
            value.Id == Guid.Parse(receipt.UpgradeId) || value.ReceiptFingerprint == authorization.ReceiptFingerprint,
            cancellationToken), "Preparation receipt was consumed by another deployment.");
        if (history.Length == 0)
        {
            CapabilityPreparationContract.Require(receipt.PreviousReceiptFingerprint is null &&
                receipt.OriginalCapabilityFactsHash == receipt.ExpectedPriorCapabilityFactsHash,
                "First preparation must preserve the actual original bootstrap facts.");
        }
        else
        {
            var previous = history.SingleOrDefault(value => value.ReceiptFingerprint == receipt.PreviousReceiptFingerprint);
            CapabilityPreparationContract.Require(previous is not null && previous.TargetCapabilityFactsJson == actualJson &&
                previous.OriginalCapabilityFactsHash == receipt.OriginalCapabilityFactsHash &&
                previous.Id == historyHead?.Id,
                "Preparation does not extend the exact current receipt chain.");
            using var original = System.Text.Json.JsonDocument.Parse(previous!.ReceiptJson);
            using var next = System.Text.Json.JsonDocument.Parse(authorization.ReceiptJson);
            foreach (var field in new[] { "tenantId", "subscriptionId", "resourceGroup", "originalStateReference",
                "originalStateFingerprint", "originalConfigurationReference", "originalConfigurationFingerprint",
                "originalBootstrapSourceFingerprint", "apiPrincipal", "workerPrincipal" })
                CapabilityPreparationContract.Require(original.RootElement.GetProperty(field).GetRawText() ==
                    next.RootElement.GetProperty(field).GetRawText(), "Original deployment provenance or principals changed.");
            var previousReceipt = CapabilityPreparationContract.Parse(previous.ReceiptJson);
            if (previousReceipt.PurviewRuntimePrincipal is { } priorPurviewPrincipal)
                CapabilityPreparationContract.Require(receipt.PurviewRuntimePrincipal == priorPurviewPrincipal,
                    "Previously introduced Purview runtime client/object principal pair changed.");
            else
                CapabilityPreparationContract.Require(receipt.PurviewRuntimePrincipal is null ||
                    actual.Capabilities.Single(value => value.Kind == ProtectionCapabilityKind.Purview).Status == ProtectionCapabilityStatus.NotInstalled &&
                    target.Capabilities.Single(value => value.Kind == ProtectionCapabilityKind.Purview).Status == ProtectionCapabilityStatus.Installed,
                    "Purview runtime principal pair can only be introduced when adding Purview.");
            CapabilityPreparationContract.Require(previousReceipt.TargetSnapshot.RoleBindings.All(role =>
                receipt.TargetSnapshot.RoleBindings.Contains(role)), "Preparation cannot replace previously verified role assignments.");
        }
        var added = false;
        foreach (var prior in existing)
        {
            var desired = target.Capabilities.Single(value => value.Kind == prior.Kind);
            if (prior.Status == desired.Status)
                CapabilityPreparationContract.Require(IdentifiersEqual(prior.ResourceIdentifiers, desired.ResourceIdentifiers),
                    "Preparation cannot replace installed or unchanged capability identities.");
            else
            {
                CapabilityPreparationContract.Require(prior.Status == ProtectionCapabilityStatus.NotInstalled &&
                    desired.Status == ProtectionCapabilityStatus.Installed && prior.Kind != ProtectionCapabilityKind.Agent365RegistrationBeta,
                    "Only additive Prompt Shields/Purview installation is supported.");
                added = true;
            }
        }
        CapabilityPreparationContract.Require(added, "Receipt contains no additive capability transition.");
        _dbContext.Set<CapabilityPreparationHistory>().Add(new CapabilityPreparationHistory
        {
            Id = Guid.Parse(receipt.UpgradeId), DeploymentOwnershipId = target.DeploymentOwnershipId,
            ApprovedPlanFingerprint = receipt.ApprovedPlanFingerprint, ReceiptFingerprint = authorization.ReceiptFingerprint,
            PreviousReceiptFingerprint = receipt.PreviousReceiptFingerprint, OriginalCapabilityFactsHash = receipt.OriginalCapabilityFactsHash,
            PriorCapabilityFactsJson = actualJson, TargetCapabilityFactsJson = targetJson,
            ReceiptJson = authorization.ReceiptJson, RecordedAtUtc = utcNow
        });
        foreach (var capability in existing)
        {
            var desired = target.Capabilities.Single(value => value.Kind == capability.Kind);
            capability.Status = desired.Status;
            capability.ResourceIdentifiers = desired.ResourceIdentifiers;
            capability.LastReadbackAtUtc = target.AttestedAtUtc;
            capability.UpdatedAtUtc = utcNow;
        }
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
