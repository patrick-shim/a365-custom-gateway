namespace Gateway.Domain.ValueObjects;

/// <summary>
/// Persistable metadata for a short-lived, one-time confirmation. The clear
/// confirmation value is deliberately not retained.
/// </summary>
public sealed class ProtectionConfirmationVerifier
{
    private readonly byte[] _verifierSalt;
    private readonly byte[] _verifierHash;

    public Guid ReviewTokenId { get; }
    public Guid ConfirmationTokenId { get; }
    public int FormatVersion { get; }
    public string HashAlgorithm { get; }
    public ReadOnlyMemory<byte> VerifierSalt => _verifierSalt.AsMemory();
    public ReadOnlyMemory<byte> VerifierHash => _verifierHash.AsMemory();
    public DateTime ExpiresAtUtc { get; }
    public DateTime? ConsumedAtUtc { get; private set; }

    public ProtectionConfirmationVerifier(
        Guid reviewTokenId,
        Guid confirmationTokenId,
        int formatVersion,
        string hashAlgorithm,
        ReadOnlySpan<byte> verifierSalt,
        ReadOnlySpan<byte> verifierHash,
        DateTime expiresAtUtc)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(reviewTokenId, Guid.Empty);
        ArgumentOutOfRangeException.ThrowIfEqual(confirmationTokenId, Guid.Empty);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(formatVersion);
        ArgumentException.ThrowIfNullOrWhiteSpace(hashAlgorithm);
        if (verifierSalt.IsEmpty)
            throw new ArgumentException("A confirmation verifier salt is required.", nameof(verifierSalt));
        if (verifierHash.IsEmpty)
            throw new ArgumentException("A confirmation verifier hash is required.", nameof(verifierHash));
        if (expiresAtUtc.Kind != DateTimeKind.Utc)
            throw new ArgumentException("The confirmation expiry must be UTC.", nameof(expiresAtUtc));

        ReviewTokenId = reviewTokenId;
        ConfirmationTokenId = confirmationTokenId;
        FormatVersion = formatVersion;
        HashAlgorithm = hashAlgorithm;
        _verifierSalt = verifierSalt.ToArray();
        _verifierHash = verifierHash.ToArray();
        ExpiresAtUtc = expiresAtUtc;
    }

    public bool IsUsableAt(DateTime utcNow) =>
        utcNow.Kind == DateTimeKind.Utc &&
        ConsumedAtUtc is null &&
        utcNow < ExpiresAtUtc;

    public void MarkConsumed(DateTime consumedAtUtc)
    {
        if (consumedAtUtc.Kind != DateTimeKind.Utc)
            throw new ArgumentException("The confirmation consumption time must be UTC.", nameof(consumedAtUtc));
        if (ConsumedAtUtc is not null)
            throw new InvalidOperationException("The one-time confirmation has already been consumed.");

        ConsumedAtUtc = consumedAtUtc;
    }
}
