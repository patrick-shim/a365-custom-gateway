using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Domain.Models;
using Gateway.Purview;

namespace Gateway.Api.Infrastructure;

internal static class AcceptedPurviewCatalog
{
    public static PurviewPolicyCatalog Deserialize(
        PurviewCatalogSnapshot snapshot,
        Guid tenantId,
        Guid connectorInstanceId)
    {
        try
        {
            if (snapshot.TenantId != tenantId || tenantId == Guid.Empty ||
                connectorInstanceId == Guid.Empty || snapshot.ConnectorInstanceId != connectorInstanceId ||
                snapshot.OperationId == Guid.Empty || snapshot.Generation <= 0 ||
                snapshot.CatalogHash is not { Length: 64 } ||
                !snapshot.CatalogHash.All(character =>
                    character is >= '0' and <= '9' or >= 'a' and <= 'f'))
                throw new InvalidDataException();
            var catalog = JsonSerializer.Deserialize<PurviewPolicyCatalog>(
                    snapshot.CatalogJson,
                    PurviewConnectorProtocol.Json)
                ?? throw new JsonException();
            PurviewPolicyCatalogValidation.Validate(catalog, tenantId);
            if ((catalog.RetrievedAtUtc.UtcDateTime - snapshot.RetrievedAtUtc.ToUniversalTime()).Duration() >
                TimeSpan.FromMilliseconds(1))
                throw new InvalidDataException();
            if (!CryptographicOperations.FixedTimeEquals(
                    Convert.FromHexString(snapshot.CatalogHash),
                    Convert.FromHexString(PurviewConnectorProtocol.Digest(catalog))))
                throw new CryptographicException();
            return catalog;
        }
        catch (Exception failure) when (failure is JsonException or FormatException or
            CryptographicException or InvalidDataException or PurviewPolicyException)
        {
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_CATALOG_INVALID",
                "The accepted Purview policy catalog failed validation.");
        }
    }
}
