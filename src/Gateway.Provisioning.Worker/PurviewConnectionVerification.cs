using System.Security.Cryptography;
using System.Text.Json;

namespace Gateway.Provisioning.Worker;

internal sealed record PurviewConnectionVerificationRequest(
    Guid OperationId,
    Guid TenantId,
    Guid AdministratorObjectId,
    Guid ExpectedAuthorityApplicationId,
    Guid ExpectedAuthorityServicePrincipalObjectId,
    string ExpectedKeyVaultResourceId,
    string ExpectedKeyVaultHost,
    string ExpectedCertificateName,
    Uri ExpectedCertificateSecretUri);

internal sealed record PurviewConnectionInventoryItem(
    Guid Id,
    string ExactName,
    string Publisher,
    int SortOrder);

internal sealed record PurviewConnectionVerificationEvidence(
    Guid OperationId,
    Guid TenantId,
    Guid AdministratorObjectId,
    Guid AuthorityApplicationId,
    Guid AuthorityServicePrincipalObjectId,
    string KeyVaultResourceId,
    string KeyVaultHost,
    string CertificateName,
    Uri CertificateSecretUri,
    Uri ProviderCertificateSecretId,
    DateTimeOffset ObservedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    Guid InventoryGenerationId,
    string EvidenceDigest,
    IReadOnlyList<PurviewConnectionInventoryItem> Items)
{
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);

    public static PurviewConnectionVerificationEvidence Create(
        Guid operationId,
        Guid tenantId,
        Guid administratorObjectId,
        Guid authorityApplicationId,
        Guid authorityServicePrincipalObjectId,
        string keyVaultResourceId,
        string keyVaultHost,
        string certificateName,
        Uri certificateSecretUri,
        Uri providerCertificateSecretId,
        DateTimeOffset observedAtUtc,
        DateTimeOffset expiresAtUtc,
        IReadOnlyList<PurviewConnectionInventoryItem> items)
    {
        ValidateIdentifier(operationId, nameof(operationId));
        ValidateIdentifier(tenantId, nameof(tenantId));
        ValidateIdentifier(administratorObjectId, nameof(administratorObjectId));
        ValidateIdentifier(authorityApplicationId, nameof(authorityApplicationId));
        ValidateIdentifier(
            authorityServicePrincipalObjectId,
            nameof(authorityServicePrincipalObjectId));
        ValidateBindingText(
            keyVaultResourceId,
            2048,
            nameof(keyVaultResourceId));
        ValidateBindingText(keyVaultHost, 255, nameof(keyVaultHost));
        ValidateBindingText(certificateName, 127, nameof(certificateName));
        ArgumentNullException.ThrowIfNull(certificateSecretUri);
        ArgumentNullException.ThrowIfNull(providerCertificateSecretId);
        if (!certificateSecretUri.IsAbsoluteUri ||
            !providerCertificateSecretId.IsAbsoluteUri)
        {
            throw new ArgumentException("A certificate reference is invalid.");
        }
        if (observedAtUtc.Offset != TimeSpan.Zero ||
            expiresAtUtc.Offset != TimeSpan.Zero ||
            expiresAtUtc <= observedAtUtc ||
            expiresAtUtc > observedAtUtc.AddMinutes(15))
        {
            throw new ArgumentException("The provider verification lifetime is invalid.");
        }

        var ordered = NormalizeItems(items);
        var digest = ComputeDigest(
            operationId,
            tenantId,
            administratorObjectId,
            authorityApplicationId,
            authorityServicePrincipalObjectId,
            keyVaultResourceId,
            keyVaultHost,
            certificateName,
            certificateSecretUri,
            ordered);
        return new(
            operationId,
            tenantId,
            administratorObjectId,
            authorityApplicationId,
            authorityServicePrincipalObjectId,
            keyVaultResourceId,
            keyVaultHost,
            certificateName,
            certificateSecretUri,
            providerCertificateSecretId,
            observedAtUtc,
            expiresAtUtc,
            DeriveGenerationId(digest),
            digest,
            ordered);
    }

    public bool HasValidDigestAndGeneration()
    {
        IReadOnlyList<PurviewConnectionInventoryItem> ordered;
        try
        {
            ordered = NormalizeItems(Items);
        }
        catch (ArgumentException)
        {
            return false;
        }

        if (!ordered.SequenceEqual(Items))
            return false;
        var digest = ComputeDigest(
            OperationId,
            TenantId,
            AdministratorObjectId,
            AuthorityApplicationId,
            AuthorityServicePrincipalObjectId,
            KeyVaultResourceId,
            KeyVaultHost,
            CertificateName,
            CertificateSecretUri,
            ordered);
        return string.Equals(digest, EvidenceDigest, StringComparison.Ordinal) &&
            InventoryGenerationId == DeriveGenerationId(digest);
    }

    public static Guid DeriveInventoryGenerationId(
        Guid operationId,
        Guid tenantId,
        Guid administratorObjectId,
        Guid authorityApplicationId,
        Guid authorityServicePrincipalObjectId,
        string keyVaultResourceId,
        string keyVaultHost,
        string certificateName,
        Uri certificateSecretUri,
        IReadOnlyList<PurviewConnectionInventoryItem> items) =>
        DeriveGenerationId(ComputeDigest(
            operationId,
            tenantId,
            administratorObjectId,
            authorityApplicationId,
            authorityServicePrincipalObjectId,
            keyVaultResourceId,
            keyVaultHost,
            certificateName,
            certificateSecretUri,
            NormalizeItems(items)));

    private static IReadOnlyList<PurviewConnectionInventoryItem> NormalizeItems(
        IReadOnlyList<PurviewConnectionInventoryItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        if (items.Count is < 1 or > 2048)
            throw new ArgumentException("The provider inventory is outside its safe bound.");

        var ids = new HashSet<Guid>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        var ordered = items
            .OrderBy(item => item.ExactName, StringComparer.Ordinal)
            .ThenBy(item => item.Id)
            .ToArray();
        for (var index = 0; index < ordered.Length; index++)
        {
            var item = ordered[index];
            ValidateIdentifier(item.Id, nameof(item.Id));
            if (!ids.Add(item.Id) ||
                !names.Add(item.ExactName) ||
                !IsBoundedText(item.ExactName, 255) ||
                !IsBoundedText(item.Publisher, 200))
            {
                throw new ArgumentException(
                    "The provider inventory contains invalid or duplicate identity.");
            }

            ordered[index] = item with { SortOrder = index };
        }

        return ordered;
    }

    private static string ComputeDigest(
        Guid operationId,
        Guid tenantId,
        Guid administratorObjectId,
        Guid authorityApplicationId,
        Guid authorityServicePrincipalObjectId,
        string keyVaultResourceId,
        string keyVaultHost,
        string certificateName,
        Uri certificateSecretUri,
        IReadOnlyList<PurviewConnectionInventoryItem> items)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            new
            {
                operationId,
                tenantId,
                administratorObjectId,
                authorityApplicationId,
                authorityServicePrincipalObjectId,
                keyVaultResourceId,
                keyVaultHost,
                certificateName,
                certificateSecretUri = certificateSecretUri.AbsoluteUri,
                items = items.Select(item => new
                {
                    item.Id,
                    item.ExactName,
                    item.Publisher,
                    item.SortOrder
                })
            },
            JsonOptions);
        try
        {
            return $"sha256:{Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()}";
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static Guid DeriveGenerationId(string digest)
    {
        var bytes = Convert.FromHexString(digest[7..]);
        try
        {
            var value = bytes.AsSpan(0, 16).ToArray();
            value[7] = (byte)((value[7] & 0x0f) | 0x40);
            value[8] = (byte)((value[8] & 0x3f) | 0x80);
            return new Guid(value);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static void ValidateIdentifier(Guid value, string name)
    {
        if (value == Guid.Empty)
            throw new ArgumentException("A provider verification identifier is invalid.", name);
    }

    private static void ValidateBindingText(
        string value,
        int maximumLength,
        string name)
    {
        if (!IsBoundedText(value, maximumLength))
            throw new ArgumentException("A capability binding value is invalid.", name);
    }

    private static bool IsBoundedText(string? value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character => character > '\u001f' && character != '\u007f');
}

internal interface IPurviewConnectionVerificationProvider
{
    Task<PurviewConnectionVerificationEvidence> VerifyAsync(
        PurviewConnectionVerificationRequest request,
        CancellationToken ct);
}

internal sealed class PurviewConnectionVerificationException : Exception
{
    public PurviewConnectionVerificationException(
        string failureCode,
        bool isTransient = false,
        Exception? innerException = null)
        : base(
            "Independent Purview connection verification failed closed.",
            innerException)
    {
        FailureCode = failureCode;
        IsTransient = isTransient;
    }

    public string FailureCode { get; }
    public bool IsTransient { get; }
}
