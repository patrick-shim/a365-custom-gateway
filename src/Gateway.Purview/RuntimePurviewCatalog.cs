using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

public sealed class RuntimePurviewCatalogOptions
{
    public const string SectionName = "RuntimePurviewCatalog";
    public bool Enabled { get; set; }
    public Guid TenantId { get; set; }
    public string SnapshotPath { get; set; } = string.Empty;
    public string CertificateBase64 { get; set; } = string.Empty;
}

public sealed record SignedPurviewCatalog(string Payload, string Signature);

public static class PurviewCatalogSignature
{
    private static byte[] SigningBytes(byte[] payload) =>
        Encoding.UTF8.GetBytes("A365Gateway.PurviewCatalog.v1\n").Concat(payload).ToArray();

    public static SignedPurviewCatalog Sign(PurviewPolicyCatalog catalog, X509Certificate2 certificate)
    {
        PurviewPolicyCatalogValidation.Validate(catalog, catalog.TenantId);
        var payload = JsonSerializer.SerializeToUtf8Bytes(catalog, PurviewCatalogJson.Options);
        using var key = certificate.GetRSAPrivateKey() ?? throw new InvalidOperationException("RSA signing key unavailable.");
        return new(Convert.ToBase64String(payload), Convert.ToBase64String(
            key.SignData(SigningBytes(payload), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)));
    }

    public static PurviewPolicyCatalog Verify(SignedPurviewCatalog envelope, X509Certificate2 certificate, Guid tenantId)
    {
        if (envelope.Payload is not { Length: > 0 and <= 2_000_000 } || envelope.Signature is not { Length: > 0 and <= 2048 } ||
            certificate.NotBefore.ToUniversalTime() > DateTime.UtcNow || certificate.NotAfter.ToUniversalTime() <= DateTime.UtcNow)
            throw new CryptographicException("Invalid catalog envelope or certificate lifetime.");
        var payload = Convert.FromBase64String(envelope.Payload);
        using var key = certificate.GetRSAPublicKey() ?? throw new CryptographicException("RSA verification key unavailable.");
        if (!key.VerifyData(SigningBytes(payload), Convert.FromBase64String(envelope.Signature), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
            throw new CryptographicException("Catalog signature is invalid.");
        var catalog = JsonSerializer.Deserialize<PurviewPolicyCatalog>(payload, PurviewCatalogJson.Options)
            ?? throw new JsonException("Missing catalog.");
        PurviewPolicyCatalogValidation.Validate(catalog, tenantId);
        return catalog;
    }
}

internal sealed class RuntimePurviewCatalogClient(IOptions<RuntimePurviewCatalogOptions> options) : IPurviewPolicyCatalogClient
{
    public async Task<PurviewPolicyCatalog> ReadAsync(Guid tenantId, CancellationToken ct)
    {
        var value = options.Value;
        if (!value.Enabled || tenantId == Guid.Empty || value.TenantId != tenantId || !Path.IsPathFullyQualified(value.SnapshotPath))
            throw new PurviewPolicyException("PURVIEW_POLICY_CATALOG_SETUP_REQUIRED", "Runtime Purview catalog access is not configured.");
        try
        {
            using var certificate = X509CertificateLoader.LoadCertificate(Convert.FromBase64String(value.CertificateBase64));
            await using var stream = new FileStream(value.SnapshotPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length is <= 0 or > 2_100_000) throw new JsonException("Catalog exceeds size bound.");
            var envelope = await JsonSerializer.DeserializeAsync<SignedPurviewCatalog>(stream, PurviewCatalogJson.Options, ct)
                ?? throw new JsonException("Missing catalog envelope.");
            return PurviewCatalogSignature.Verify(envelope, certificate, tenantId);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or CryptographicException or FormatException or JsonException or ArgumentException)
        {
            throw new PurviewPolicyException("PURVIEW_POLICY_CATALOG_UNAVAILABLE", "A current authenticated Purview policy catalog is unavailable.");
        }
    }
}
