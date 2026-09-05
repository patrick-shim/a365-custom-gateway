using System.Security.Cryptography;
using System.Text.Json;

namespace Gateway.Contracts.Dtos;

public sealed record PurviewTenantConnectionDto(
    Guid Id,
    Guid TenantId,
    string Status,
    string? AuthorityKind,
    Guid? AuthorityApplicationId,
    Guid? AuthorityServicePrincipalObjectId,
    Guid? ActiveInventoryGenerationId,
    DateTime? AuthorizedAtUtc,
    DateTime? ExpiresAtUtc,
    DateTime? LastVerifiedAtUtc,
    string? LastFailureCode,
    string RowVersion);

/// <summary>
/// Bounded companion evidence. It contains no access token, credential,
/// certificate material, or provider response body.
/// </summary>
public sealed record PurviewTenantConnectionEvidenceDto(
    Guid TenantId,
    Guid AdministratorObjectId,
    IReadOnlyList<string> AuthorizedCapabilities,
    DateTimeOffset ObservedAtUtc,
    DateTimeOffset InventoryExpiresAtUtc,
    IReadOnlyList<PurviewSensitiveInformationTypeDto> SensitiveInformationTypes);

public sealed record PurviewCompanionLaunchDto(
    Guid OperationId,
    Guid InventoryGenerationId,
    DateTimeOffset ExpiresAtUtc,
    string ScriptRelativePath,
    IReadOnlyList<string> Arguments);

public static class PurviewTenantConnectionEvidenceDigest
{
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);

    public static string Compute(
        Guid operationId,
        Guid inventoryGenerationId,
        PurviewTenantConnectionEvidenceDto evidence)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(operationId, Guid.Empty);
        ArgumentOutOfRangeException.ThrowIfEqual(
            inventoryGenerationId,
            Guid.Empty);
        ArgumentNullException.ThrowIfNull(evidence);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operationId,
            inventoryGenerationId,
            evidence.TenantId,
            evidence.AdministratorObjectId,
            authorizedCapabilities =
                evidence.AuthorizedCapabilities.ToArray(),
            observedAtUtc = evidence.ObservedAtUtc.ToUniversalTime(),
            inventoryExpiresAtUtc =
                evidence.InventoryExpiresAtUtc.ToUniversalTime(),
            sensitiveInformationTypes =
                evidence.SensitiveInformationTypes
                    .OrderBy(item => item.ExactName, StringComparer.Ordinal)
                    .ThenBy(item => item.Id)
                    .Select(item => new
                    {
                        item.Id,
                        item.ExactName,
                        item.Publisher
                    })
                    .ToArray()
        }, JsonOptions);
        try
        {
            return
                $"sha256:{Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()}";
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}
