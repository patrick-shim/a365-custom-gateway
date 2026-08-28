using System.Security.Cryptography;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Security;

internal sealed class AgentIngressCredentialService : IAgentIngressCredentialService
{
    internal const int CurrentFormatVersion = 1;
    internal const string CurrentHashAlgorithm = "SHA-256";
    internal const string ApiKeyPrefix = "a365gw_v1_";

    private const int SecretLengthBytes = 32;
    private const int EncodedSecretLength = 43;
    private const int SaltLengthBytes = 32;
    private const int HashLengthBytes = 32;

    private readonly GatewayDbContext _dbContext;
    private readonly AgentIngressCredentialOptions _options;

    public AgentIngressCredentialService(
        GatewayDbContext dbContext,
        IOptions<AgentIngressCredentialOptions> options)
    {
        _dbContext = dbContext;
        _options = options.Value;
    }

    public IssuedAgentIngressCredential Issue(
        Guid agentRegistrationId,
        string createdByObjectId,
        DateTime issuedAtUtc)
    {
        var credentialId = Guid.NewGuid();
        var secret = RandomNumberGenerator.GetBytes(SecretLengthBytes);
        var salt = RandomNumberGenerator.GetBytes(SaltLengthBytes);

        try
        {
            var credential = new AgentIngressCredential
            {
                Id = credentialId,
                AgentRegistrationId = agentRegistrationId,
                FormatVersion = CurrentFormatVersion,
                HashAlgorithm = CurrentHashAlgorithm,
                SecretSalt = salt,
                SecretHash = ComputeHash(salt, secret),
                CreatedAtUtc = issuedAtUtc,
                CreatedByObjectId = createdByObjectId,
                ExpiresAtUtc = issuedAtUtc.AddDays(_options.LifetimeDays)
            };

            _dbContext.AgentIngressCredentials.Add(credential);

            var apiKey = $"{ApiKeyPrefix}{credentialId:N}.{Base64UrlEncode(secret)}";
            return new IssuedAgentIngressCredential(credential, apiKey);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    public async Task<AgentIngressCredentialIdentity?> ValidateAsync(
        string presentedApiKey,
        DateTime validatedAtUtc,
        CancellationToken cancellationToken)
    {
        if (!TryParse(presentedApiKey, out var credentialId, out var secret))
            return null;

        try
        {
            var credential = await _dbContext.AgentIngressCredentials
                .AsNoTracking()
                .Include(item => item.AgentRegistration)
                .SingleOrDefaultAsync(item => item.Id == credentialId, cancellationToken);

            if (credential is null ||
                credential.FormatVersion != CurrentFormatVersion ||
                !string.Equals(
                credential.HashAlgorithm,
                    CurrentHashAlgorithm,
                    StringComparison.Ordinal) ||
                credential.RevokedAtUtc is not null ||
                credential.ExpiresAtUtc <= validatedAtUtc ||
                credential.AgentRegistration.IsDeleted ||
                credential.SecretSalt.Length != SaltLengthBytes ||
                credential.SecretHash.Length != HashLengthBytes)
            {
                return null;
            }

            var candidateHash = ComputeHash(credential.SecretSalt, secret);
            try
            {
                if (!CryptographicOperations.FixedTimeEquals(
                        candidateHash,
                        credential.SecretHash))
                {
                    return null;
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(candidateHash);
            }

            return new AgentIngressCredentialIdentity(
                credential.Id,
                credential.AgentRegistrationId,
                credential.AgentRegistration.ExternalAgentId.Value);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    public async Task<IReadOnlyList<AgentIngressCredentialMetadata>> ListAsync(
        Guid agentRegistrationId,
        CancellationToken cancellationToken)
    {
        return await _dbContext.AgentIngressCredentials
            .AsNoTracking()
            .Where(item => item.AgentRegistrationId == agentRegistrationId)
            .OrderByDescending(item => item.CreatedAtUtc)
            .ThenByDescending(item => item.Id)
            .Select(item => new AgentIngressCredentialMetadata(
                item.Id,
                item.CreatedAtUtc,
                item.ExpiresAtUtc,
                item.RevokedAtUtc))
            .ToListAsync(cancellationToken);
    }

    public async Task<AgentIngressCredentialRevocationResult> RevokeAsync(
        Guid agentRegistrationId,
        Guid credentialId,
        DateTime revokedAtUtc,
        CancellationToken cancellationToken)
    {
        var credential = await _dbContext.AgentIngressCredentials
            .SingleOrDefaultAsync(
                item => item.Id == credentialId &&
                        item.AgentRegistrationId == agentRegistrationId,
                cancellationToken);

        if (credential is null)
        {
            return new AgentIngressCredentialRevocationResult(
                AgentIngressCredentialRevocationStatus.NotFound,
                null);
        }

        var metadata = ToMetadata(credential);
        if (credential.RevokedAtUtc is not null)
        {
            return new AgentIngressCredentialRevocationResult(
                AgentIngressCredentialRevocationStatus.AlreadyRevoked,
                metadata);
        }

        if (credential.ExpiresAtUtc > revokedAtUtc)
        {
            var usableCredentialCount = await _dbContext.AgentIngressCredentials
                .CountAsync(
                    item => item.AgentRegistrationId == agentRegistrationId &&
                            item.RevokedAtUtc == null &&
                            item.ExpiresAtUtc > revokedAtUtc,
                    cancellationToken);

            if (usableCredentialCount <= 1)
            {
                return new AgentIngressCredentialRevocationResult(
                    AgentIngressCredentialRevocationStatus.LastUsableCredential,
                    metadata);
            }
        }

        credential.RevokedAtUtc = revokedAtUtc;
        return new AgentIngressCredentialRevocationResult(
            AgentIngressCredentialRevocationStatus.Revoked,
            ToMetadata(credential));
    }

    private static AgentIngressCredentialMetadata ToMetadata(
        AgentIngressCredential credential) => new(
            credential.Id,
            credential.CreatedAtUtc,
            credential.ExpiresAtUtc,
            credential.RevokedAtUtc);

    private static byte[] ComputeHash(byte[] salt, byte[] secret)
    {
        var input = new byte[salt.Length + secret.Length];
        try
        {
            salt.CopyTo(input, 0);
            secret.CopyTo(input, salt.Length);
            return SHA256.HashData(input);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(input);
        }
    }

    private static bool TryParse(
        string presentedApiKey,
        out Guid credentialId,
        out byte[] secret)
    {
        credentialId = Guid.Empty;
        secret = [];

        if (string.IsNullOrWhiteSpace(presentedApiKey) ||
            presentedApiKey.Length != ApiKeyPrefix.Length + 32 + 1 + EncodedSecretLength ||
            !presentedApiKey.StartsWith(ApiKeyPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        var separatorIndex = presentedApiKey.IndexOf('.', ApiKeyPrefix.Length);
        if (separatorIndex < 0 ||
            presentedApiKey.IndexOf('.', separatorIndex + 1) >= 0)
        {
            return false;
        }

        var keyIdText = presentedApiKey[ApiKeyPrefix.Length..separatorIndex];
        if (keyIdText.Length != 32 ||
            !Guid.TryParseExact(keyIdText, "N", out credentialId))
        {
            return false;
        }

        try
        {
            secret = Base64UrlDecode(presentedApiKey[(separatorIndex + 1)..]);
            if (secret.Length == SecretLengthBytes &&
                string.Equals(
                    Base64UrlEncode(secret),
                    presentedApiKey[(separatorIndex + 1)..],
                    StringComparison.Ordinal))
            {
                return true;
            }

            CryptographicOperations.ZeroMemory(secret);
            secret = [];
            return false;
        }
        catch (FormatException)
        {
            secret = [];
            return false;
        }
    }

    private static string Base64UrlEncode(byte[] value) =>
        Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        if (value.Length == 0 || value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_')))
        {
            throw new FormatException("Invalid base64url value.");
        }

        var base64 = value.Replace('-', '+').Replace('_', '/');
        var paddingLength = (4 - (base64.Length % 4)) % 4;
        return Convert.FromBase64String(base64.PadRight(base64.Length + paddingLength, '='));
    }
}
