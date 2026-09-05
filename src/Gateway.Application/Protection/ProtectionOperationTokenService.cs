using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Application.Protection;

internal sealed class ProtectionOperationTokenService
{
    internal const int Pbkdf2Iterations = 210_000;
    private const int TokenEntropyBytes = 32;
    private const int SaltBytes = 32;
    private const int VerifierBytes = 32;
    private const int MaximumTokenCharacters = 16_384;
    private static readonly TimeSpan ReviewLifetime = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan ConfirmationLifetime = TimeSpan.FromMinutes(5);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 12,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private readonly TimeProvider _timeProvider;

    public ProtectionOperationTokenService(TimeProvider timeProvider)
    {
        _timeProvider = timeProvider;
    }

    public ProtectionIssuedToken IssueReview<T>(
        ProtectionAdminOperation operation,
        string expectedRowVersion,
        T payload)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedRowVersion);
        ArgumentNullException.ThrowIfNull(payload);

        var payloadElement = JsonSerializer.SerializeToElement(payload, JsonOptions);
        var reviewedPayloadHash = ComputePayloadHash(payloadElement);
        var expiresAtUtc = UtcNow().Add(ReviewLifetime);
        var envelope = CreateEnvelope(
            "review",
            operation,
            expectedRowVersion,
            reviewedPayloadHash,
            payloadElement,
            expiresAtUtc);

        return Issue(envelope, reviewedPayloadHash);
    }

    public ProtectionIssuedToken ExchangeReview(
        ProtectionAdminOperation operation,
        ProtectionActor actor,
        string reviewToken)
    {
        var validated = Validate(
            operation,
            actor,
            reviewToken,
            expectedKind: "review",
            expectedRowVersion: null,
            expiredCode: ErrorCodes.PROTECTION_REVIEW_EXPIRED);
        var expiresAtUtc = UtcNow().Add(ConfirmationLifetime);
        var envelope = CreateEnvelope(
            "confirmation",
            operation,
            validated.ExpectedRowVersion,
            validated.ReviewedPayloadHash,
            validated.Payload,
            expiresAtUtc);

        return Issue(envelope, validated.ReviewedPayloadHash);
    }

    public ProtectionValidatedToken ValidateConfirmation(
        ProtectionAdminOperation operation,
        ProtectionActor actor,
        string confirmationToken,
        string expectedRowVersion) =>
        Validate(
            operation,
            actor,
            confirmationToken,
            expectedKind: "confirmation",
            expectedRowVersion,
            ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

    private ProtectionValidatedToken Validate(
        ProtectionAdminOperation operation,
        ProtectionActor actor,
        string token,
        string expectedKind,
        string? expectedRowVersion,
        string expiredCode)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(actor);

        var verifier = operation.ConfirmationVerifier;
        var now = UtcNow();
        if (verifier is null ||
            verifier.ReviewTokenId != operation.Id ||
            verifier.ConfirmationTokenId != operation.Id ||
            verifier.ConsumedAtUtc is not null)
        {
            throw InvalidToken();
        }

        if (now >= verifier.ExpiresAtUtc)
        {
            throw new DomainException(
                "The protection operation authorization expired. Review the operation again.",
                expiredCode);
        }

        if (string.IsNullOrWhiteSpace(token) ||
            token.Length > MaximumTokenCharacters ||
            !Verify(token, verifier))
        {
            throw InvalidToken();
        }

        TokenEnvelope envelope;
        try
        {
            envelope = ParseEnvelope(token);
        }
        catch (Exception exception) when (
            exception is FormatException or JsonException or DecoderFallbackException)
        {
            throw InvalidToken();
        }

        if (!string.Equals(envelope.Kind, expectedKind, StringComparison.Ordinal) ||
            envelope.TokenId != operation.Id ||
            envelope.TenantId != actor.TenantId ||
            !string.Equals(envelope.ActorObjectId, actor.ObjectId, StringComparison.Ordinal) ||
            !string.Equals(envelope.OperationType, operation.Type.ToString(), StringComparison.Ordinal) ||
            !string.Equals(envelope.TargetType, operation.TargetType.ToString(), StringComparison.Ordinal) ||
            !string.Equals(envelope.TargetIdentifier, operation.TargetIdentifier, StringComparison.Ordinal) ||
            !string.Equals(
                envelope.ReviewedPayloadHash,
                operation.ReviewedPayloadHash,
                StringComparison.Ordinal) ||
            !string.Equals(
                envelope.ReviewedPayloadHash,
                ComputePayloadHash(envelope.Payload),
                StringComparison.Ordinal) ||
            envelope.ExpiresAtUtc.Kind != DateTimeKind.Utc ||
            envelope.ExpiresAtUtc != verifier.ExpiresAtUtc ||
            now >= envelope.ExpiresAtUtc ||
            (expectedRowVersion is not null &&
             !string.Equals(
                 envelope.ExpectedRowVersion,
                 expectedRowVersion,
                 StringComparison.Ordinal)))
        {
            throw InvalidToken();
        }

        return new ProtectionValidatedToken(
            envelope.ExpectedRowVersion,
            envelope.ReviewedPayloadHash,
            envelope.Payload.Clone());
    }

    private static TokenEnvelope CreateEnvelope(
        string kind,
        ProtectionAdminOperation operation,
        string expectedRowVersion,
        string reviewedPayloadHash,
        JsonElement payload,
        DateTime expiresAtUtc) =>
        new(
            FormatVersion: 1,
            Kind: kind,
            TokenId: operation.Id,
            TenantId: operation.TenantId.Value,
            ActorObjectId: operation.ActorObjectId,
            OperationType: operation.Type.ToString(),
            TargetType: operation.TargetType.ToString(),
            TargetIdentifier: operation.TargetIdentifier,
            ExpectedRowVersion: expectedRowVersion,
            ReviewedPayloadHash: reviewedPayloadHash,
            ExpiresAtUtc: expiresAtUtc,
            Payload: payload.Clone());

    private static ProtectionIssuedToken Issue(
        TokenEnvelope envelope,
        string reviewedPayloadHash)
    {
        var envelopeBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);
        var entropy = RandomNumberGenerator.GetBytes(TokenEntropyBytes);
        string token;
        try
        {
            token = $"{Base64UrlEncode(envelopeBytes)}.{Base64UrlEncode(entropy)}";
        }
        finally
        {
            CryptographicOperations.ZeroMemory(envelopeBytes);
            CryptographicOperations.ZeroMemory(entropy);
        }

        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var verifierHash = DeriveVerifier(token, salt);
        try
        {
            var verifier = new ProtectionConfirmationVerifier(
                envelope.TokenId,
                envelope.TokenId,
                formatVersion: 1,
                hashAlgorithm: $"PBKDF2-SHA256-{Pbkdf2Iterations}",
                salt,
                verifierHash,
                envelope.ExpiresAtUtc);
            return new ProtectionIssuedToken(
                token,
                reviewedPayloadHash,
                envelope.ExpiresAtUtc,
                verifier,
                envelope.ExpectedRowVersion,
                envelope.Payload.Clone());
        }
        finally
        {
            CryptographicOperations.ZeroMemory(salt);
            CryptographicOperations.ZeroMemory(verifierHash);
        }
    }

    private static bool Verify(
        string token,
        ProtectionConfirmationVerifier verifier)
    {
        if (verifier.FormatVersion != 1 ||
            !string.Equals(
                verifier.HashAlgorithm,
                $"PBKDF2-SHA256-{Pbkdf2Iterations}",
                StringComparison.Ordinal) ||
            verifier.VerifierSalt.IsEmpty ||
            verifier.VerifierHash.Length != VerifierBytes)
        {
            return false;
        }

        var candidate = DeriveVerifier(token, verifier.VerifierSalt.Span);
        try
        {
            return CryptographicOperations.FixedTimeEquals(
                candidate,
                verifier.VerifierHash.Span);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(candidate);
        }
    }

    private static byte[] DeriveVerifier(
        string token,
        ReadOnlySpan<byte> salt)
    {
        var tokenBytes = Encoding.UTF8.GetBytes(token);
        try
        {
            return Rfc2898DeriveBytes.Pbkdf2(
                tokenBytes,
                salt,
                Pbkdf2Iterations,
                HashAlgorithmName.SHA256,
                VerifierBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(tokenBytes);
        }
    }

    private static TokenEnvelope ParseEnvelope(string token)
    {
        var separator = token.IndexOf('.');
        if (separator <= 0 ||
            separator == token.Length - 1 ||
            token.IndexOf('.', separator + 1) >= 0)
        {
            throw new FormatException("Invalid token format.");
        }

        var entropy = Base64UrlDecode(token[(separator + 1)..]);
        try
        {
            if (entropy.Length != TokenEntropyBytes)
            {
                throw new FormatException("Invalid token entropy.");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(entropy);
        }

        var envelopeBytes = Base64UrlDecode(token[..separator]);
        try
        {
            return JsonSerializer.Deserialize<TokenEnvelope>(envelopeBytes, JsonOptions)
                ?? throw new JsonException("The token envelope is empty.");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(envelopeBytes);
        }
    }

    internal static string ComputePayloadHash(JsonElement payload)
    {
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        try
        {
            return $"sha256:{Convert.ToHexString(SHA256.HashData(payloadBytes)).ToLowerInvariant()}";
        }
        finally
        {
            CryptographicOperations.ZeroMemory(payloadBytes);
        }
    }

    private static string Base64UrlEncode(ReadOnlySpan<byte> value) =>
        Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        var base64 = value.Replace('-', '+').Replace('_', '/');
        var padding = base64.Length % 4;
        if (padding == 1)
        {
            throw new FormatException("Invalid base64url value.");
        }

        if (padding > 0)
        {
            base64 = base64.PadRight(base64.Length + 4 - padding, '=');
        }

        return Convert.FromBase64String(base64);
    }

    private DateTime UtcNow() => _timeProvider.GetUtcNow().UtcDateTime;

    private static DomainException InvalidToken() =>
        new(
            "The protection operation authorization is invalid or has already been used.",
            ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

    private sealed record TokenEnvelope(
        int FormatVersion,
        string Kind,
        Guid TokenId,
        Guid TenantId,
        string ActorObjectId,
        string OperationType,
        string TargetType,
        string TargetIdentifier,
        string ExpectedRowVersion,
        string ReviewedPayloadHash,
        DateTime ExpiresAtUtc,
        JsonElement Payload);
}

internal sealed record ProtectionIssuedToken(
    string Token,
    string ReviewedPayloadHash,
    DateTime ExpiresAtUtc,
    ProtectionConfirmationVerifier Verifier,
    string ExpectedRowVersion,
    JsonElement Payload);

internal sealed record ProtectionValidatedToken(
    string ExpectedRowVersion,
    string ReviewedPayloadHash,
    JsonElement Payload);
