using System.Collections.Frozen;
using System.Text.Json;
using Gateway.Domain.Enums;

namespace Gateway.Purview;

public sealed record PurviewTokenRoleAttestation(
    ProtectionTokenRoleStatus Status,
    DateTimeOffset ObservedAtUtc,
    DateTimeOffset? CredentialExpiresAtUtc,
    string? FailureCode);

public interface IPurviewTokenRoleAttestor
{
    Task<PurviewTokenRoleAttestation> AttestAsync(
        Guid expectedTenantId,
        CancellationToken cancellationToken);
}

internal sealed record PurviewTokenRoleSnapshot(
    IReadOnlySet<string> Roles,
    DateTimeOffset ExpiresAtUtc,
    Guid TenantId,
    string Audience);

internal interface IPurviewTokenRoleSource
{
    ValueTask<PurviewTokenRoleSnapshot> ReadAsync(CancellationToken cancellationToken);
}

internal sealed class PurviewTokenRoleAttestor : IPurviewTokenRoleAttestor
{
    public static IReadOnlySet<string> RequiredRoles { get; } =
        new[]
        {
            "Content.Process.User",
            "ContentActivity.Write",
            "ProtectionScopes.Compute.User"
        }.ToFrozenSet(StringComparer.Ordinal);

    private static readonly IReadOnlySet<string> MicrosoftGraphAudiences =
        new[]
        {
            "00000003-0000-0000-c000-000000000000",
            "https://graph.microsoft.com"
        }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    private readonly IPurviewTokenRoleSource _source;

    internal PurviewTokenRoleAttestor(IPurviewTokenRoleSource source)
    {
        _source = source;
    }

    public async Task<PurviewTokenRoleAttestation> AttestAsync(
        Guid expectedTenantId,
        CancellationToken cancellationToken)
    {
        var observedAtUtc = DateTimeOffset.UtcNow;
        if (expectedTenantId == Guid.Empty)
        {
            return new(
                ProtectionTokenRoleStatus.Failed,
                observedAtUtc,
                null,
                "PURVIEW_TOKEN_TENANT_INVALID");
        }

        try
        {
            var snapshot = await _source.ReadAsync(cancellationToken);
            if (snapshot.TenantId != expectedTenantId)
            {
                return new(
                    ProtectionTokenRoleStatus.Failed,
                    observedAtUtc,
                    snapshot.ExpiresAtUtc,
                    "PURVIEW_TOKEN_TENANT_MISMATCH");
            }
            if (!MicrosoftGraphAudiences.Contains(snapshot.Audience))
            {
                return new(
                    ProtectionTokenRoleStatus.Failed,
                    observedAtUtc,
                    snapshot.ExpiresAtUtc,
                    "PURVIEW_TOKEN_AUDIENCE_MISMATCH");
            }
            if (snapshot.ExpiresAtUtc <= observedAtUtc.AddMinutes(1))
            {
                return new(
                    ProtectionTokenRoleStatus.PendingRefresh,
                    observedAtUtc,
                    snapshot.ExpiresAtUtc,
                    "PURVIEW_TOKEN_REFRESH_REQUIRED");
            }

            var status = RequiredRoles.All(snapshot.Roles.Contains)
                ? ProtectionTokenRoleStatus.Ready
                : ProtectionTokenRoleStatus.MissingRequiredRoles;
            return new(
                status,
                observedAtUtc,
                snapshot.ExpiresAtUtc,
                status == ProtectionTokenRoleStatus.Ready
                    ? null
                    : "PURVIEW_TOKEN_REQUIRED_ROLES_MISSING");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return new(
                ProtectionTokenRoleStatus.Failed,
                observedAtUtc,
                null,
                "PURVIEW_TOKEN_ROLE_ATTESTATION_FAILED");
        }
    }
}

internal sealed class ManagedIdentityPurviewTokenRoleSource : IPurviewTokenRoleSource
{
    private const int MaximumEncodedCredentialLength = 32 * 1024;
    private const int MaximumDecodedPayloadBytes = 16 * 1024;
    private const int MaximumRoleCount = 64;
    private const int MaximumRoleLength = 128;
    private readonly IPurviewTokenProvider _tokenProvider;

    public ManagedIdentityPurviewTokenRoleSource(IPurviewTokenProvider tokenProvider)
    {
        _tokenProvider = tokenProvider;
    }

    public async ValueTask<PurviewTokenRoleSnapshot> ReadAsync(
        CancellationToken cancellationToken)
    {
        var credential = await _tokenProvider.GetTokenAsync(cancellationToken);
        var claims = ReadClaimsInMemory(credential.Token);
        return new(
            claims.Roles,
            credential.ExpiresOn,
            claims.TenantId,
            claims.Audience);
    }

    private static PurviewTokenClaims ReadClaimsInMemory(string encodedCredential)
    {
        if (string.IsNullOrWhiteSpace(encodedCredential) ||
            encodedCredential.Length > MaximumEncodedCredentialLength)
        {
            throw new FormatException("The managed-identity credential shape is invalid.");
        }

        var segments = encodedCredential.Split('.');
        if (segments.Length != 3)
            throw new FormatException("The managed-identity credential shape is invalid.");

        var payload = DecodeBase64Url(segments[1]);
        if (payload.Length > MaximumDecodedPayloadBytes)
            throw new FormatException("The managed-identity credential claim set is too large.");

        using var document = JsonDocument.Parse(payload, new JsonDocumentOptions
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 8
        });
        if (!document.RootElement.TryGetProperty("tid", out var tenantElement) ||
            tenantElement.ValueKind != JsonValueKind.String ||
            !Guid.TryParse(tenantElement.GetString(), out var tenantId) ||
            tenantId == Guid.Empty ||
            !document.RootElement.TryGetProperty("aud", out var audienceElement) ||
            audienceElement.ValueKind != JsonValueKind.String ||
            !PurviewTenantConnectionEvidenceValidator.IsBoundedText(
                audienceElement.GetString(),
                MaximumRoleLength))
        {
            throw new FormatException("The managed-identity credential claim set is invalid.");
        }

        var audience = audienceElement.GetString()!;
        if (!document.RootElement.TryGetProperty("roles", out var rolesElement) ||
            rolesElement.ValueKind != JsonValueKind.Array ||
            rolesElement.GetArrayLength() is < 1 or > MaximumRoleCount)
        {
            return new(
                new HashSet<string>(StringComparer.Ordinal),
                tenantId,
                audience);
        }

        var roles = new HashSet<string>(StringComparer.Ordinal);
        foreach (var element in rolesElement.EnumerateArray())
        {
            if (element.ValueKind != JsonValueKind.String)
                throw new FormatException("The managed-identity role claim is invalid.");

            var role = element.GetString();
            if (!PurviewTenantConnectionEvidenceValidator.IsBoundedText(
                    role,
                    MaximumRoleLength) ||
                !roles.Add(role!))
            {
                throw new FormatException("The managed-identity role claim is invalid.");
            }
        }

        return new(roles, tenantId, audience);
    }

    private static byte[] DecodeBase64Url(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized += (normalized.Length % 4) switch
        {
            0 => string.Empty,
            2 => "==",
            3 => "=",
            _ => throw new FormatException("The managed-identity credential shape is invalid.")
        };
        return Convert.FromBase64String(normalized);
    }

    private sealed record PurviewTokenClaims(
        IReadOnlySet<string> Roles,
        Guid TenantId,
        string Audience);
}
