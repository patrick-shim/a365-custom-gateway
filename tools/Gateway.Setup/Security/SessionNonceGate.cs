using System.Security.Cryptography;
using Microsoft.AspNetCore.WebUtilities;

namespace Gateway.Setup.Security;

internal sealed class SessionNonceGate
{
    private const int NonceByteCount = 32;
    private readonly object sync = new();
    private readonly byte[] expectedHash;
    private bool consumed;

    private SessionNonceGate(string nonce)
    {
        expectedHash = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(nonce));
    }

    public static NonceIssue Create()
    {
        var bytes = RandomNumberGenerator.GetBytes(NonceByteCount);
        try
        {
            var nonce = WebEncoders.Base64UrlEncode(bytes);
            return new NonceIssue(nonce, new SessionNonceGate(nonce));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    internal static SessionNonceGate FromKnownNonce(string nonce) => new(nonce);

    public bool TryConsume(string? candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate) || candidate.Length > 128)
        {
            return false;
        }

        var candidateBytes = System.Text.Encoding.UTF8.GetBytes(candidate);
        var candidateHash = SHA256.HashData(candidateBytes);
        CryptographicOperations.ZeroMemory(candidateBytes);

        try
        {
            lock (sync)
            {
                if (consumed || !CryptographicOperations.FixedTimeEquals(expectedHash, candidateHash))
                {
                    return false;
                }

                consumed = true;
                CryptographicOperations.ZeroMemory(expectedHash);
                return true;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(candidateHash);
        }
    }
}

internal sealed record NonceIssue(string Nonce, SessionNonceGate Gate);
