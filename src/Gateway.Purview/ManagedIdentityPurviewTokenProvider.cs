using System.Security.Cryptography;
using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Identity;
using Gateway.Domain.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

public interface IPurviewRuntimeIdentityBinding
{
    bool IsExact(string? clientId, Guid? principalObjectId);
}

internal sealed class ManagedIdentityPurviewTokenProvider : IPurviewTokenProvider
{
    private const int MaximumEncodedTokenLength = 32 * 1024;
    private const int MaximumDecodedPayloadBytes = 16 * 1024;
    private const string RuntimeClientIdKey =
        "PurviewRuntimeIdentity:ManagedIdentityClientId";
    private const string RuntimePrincipalObjectIdKey =
        "PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId";
    private static readonly TokenRequestContext GraphTokenRequest =
        new(["https://graph.microsoft.com/.default"]);

    private readonly TokenCredential _credential;
    private readonly Guid? _expectedPrincipalObjectId;
    private readonly IPurviewRuntimeIdentityBinding? _runtimeBinding;
    private readonly string? _managedIdentityClientId;

    public ManagedIdentityPurviewTokenProvider(
        IOptions<PurviewOptions> options,
        IConfiguration configuration,
        IPurviewRuntimeIdentityBinding? runtimeBinding = null)
        : this(CreateRuntimeIdentityBinding(options.Value, configuration), runtimeBinding, options.Value.Enabled)
    {
    }

    private ManagedIdentityPurviewTokenProvider(
        RuntimeIdentityBinding binding, IPurviewRuntimeIdentityBinding? runtimeBinding, bool enabled)
        : this(CreateCredential(binding.ManagedIdentityClientId), binding.PrincipalObjectId)
    {
        _runtimeBinding = runtimeBinding;
        _managedIdentityClientId = binding.ManagedIdentityClientId;
        if (enabled)
            EnsureRuntimeBinding();
    }

    internal ManagedIdentityPurviewTokenProvider(
        TokenCredential credential,
        Guid? expectedPrincipalObjectId = null,
        IPurviewRuntimeIdentityBinding? runtimeBinding = null,
        string? managedIdentityClientId = null)
    {
        _credential = credential;
        _expectedPrincipalObjectId = expectedPrincipalObjectId;
        _runtimeBinding = runtimeBinding;
        _managedIdentityClientId = managedIdentityClientId;
    }

    public async ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
    {
        try
        {
            EnsureRuntimeBinding();
            var token = await _credential.GetTokenAsync(GraphTokenRequest, cancellationToken);
            if (string.IsNullOrWhiteSpace(token.Token))
                throw Failure("PURVIEW_TOKEN_EMPTY", "The Purview identity returned an empty Microsoft Graph token.");

            if (token.ExpiresOn <= DateTimeOffset.UtcNow.AddMinutes(1))
            {
                throw Failure(
                    "PURVIEW_TOKEN_EXPIRED",
                    "The Purview identity returned an expired Microsoft Graph token.",
                    isTransient: true);
            }

            ValidateSubject(token.Token);
            return token;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (PurviewPolicyException)
        {
            throw;
        }
        catch (CredentialUnavailableException exception)
        {
            throw Failure(
                "PURVIEW_CREDENTIAL_UNAVAILABLE",
                "The managed identity credential for Purview is unavailable.",
                innerException: exception);
        }
        catch (AuthenticationFailedException exception) when (IsTransient(exception))
        {
            throw Failure(
                "PURVIEW_TOKEN_TRANSIENT",
                "Microsoft Graph token acquisition for Purview is temporarily unavailable.",
                isTransient: true,
                innerException: exception);
        }
        catch (AuthenticationFailedException exception)
        {
            throw Failure(
                "PURVIEW_TOKEN_ACQUISITION_FAILED",
                "Microsoft Graph token acquisition for Purview failed.",
                innerException: exception);
        }
    }

    private static RuntimeIdentityBinding CreateRuntimeIdentityBinding(
        PurviewOptions options,
        IConfiguration configuration)
    {
        var clientIdText = configuration[RuntimeClientIdKey];
        var principalIdText = configuration[RuntimePrincipalObjectIdKey];
        var hasClientId = !string.IsNullOrWhiteSpace(clientIdText);
        var hasPrincipalId = !string.IsNullOrWhiteSpace(principalIdText);

        if (hasClientId != hasPrincipalId)
        {
            throw new InvalidOperationException(
                "The Purview runtime managed-identity binding is incomplete.");
        }

        if (!hasClientId)
        {
            if (options.Enabled)
            {
                throw new InvalidOperationException(
                    "The Purview runtime managed identity is not configured.");
            }

            return new(options.ManagedIdentityClientId, null);
        }

        if (!TryParseCanonicalGuid(clientIdText, out var clientId) ||
            !TryParseCanonicalGuid(principalIdText, out var principalId))
        {
            throw new InvalidOperationException(
                "The Purview runtime managed-identity binding is invalid.");
        }

        if (!string.IsNullOrWhiteSpace(options.ManagedIdentityClientId) &&
            !string.Equals(
                options.ManagedIdentityClientId,
                clientId.ToString("D"),
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The Purview runtime managed-identity bindings conflict.");
        }

        return new(clientId.ToString("D"), principalId);
    }

    private void EnsureRuntimeBinding()
    {
        if (_runtimeBinding is not null &&
            !_runtimeBinding.IsExact(_managedIdentityClientId, _expectedPrincipalObjectId))
        {
            throw Failure("PURVIEW_CAPABILITY_BINDING_INVALID",
                "The Purview runtime identity does not match its bootstrap capability attestation.");
        }
    }

    private static TokenCredential CreateCredential(string? managedIdentityClientId) =>
        string.IsNullOrWhiteSpace(managedIdentityClientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(managedIdentityClientId));

    private void ValidateSubject(string encodedToken)
    {
        if (_expectedPrincipalObjectId is not { } expectedPrincipalObjectId)
            return;

        byte[]? payload = null;
        try
        {
            if (string.IsNullOrWhiteSpace(encodedToken) ||
                encodedToken.Length > MaximumEncodedTokenLength)
            {
                throw SubjectFailure("PURVIEW_TOKEN_SUBJECT_INVALID");
            }

            var segments = encodedToken.Split('.');
            if (segments.Length != 3)
                throw SubjectFailure("PURVIEW_TOKEN_SUBJECT_INVALID");

            payload = DecodeBase64Url(segments[1]);
            if (payload.Length > MaximumDecodedPayloadBytes)
                throw SubjectFailure("PURVIEW_TOKEN_SUBJECT_INVALID");

            using var document = JsonDocument.Parse(payload, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8
            });
            if (!document.RootElement.TryGetProperty("oid", out var subjectElement) ||
                subjectElement.ValueKind != JsonValueKind.String ||
                !TryParseCanonicalGuid(subjectElement.GetString(), out var subject))
            {
                throw SubjectFailure("PURVIEW_TOKEN_SUBJECT_INVALID");
            }

            if (subject != expectedPrincipalObjectId)
                throw SubjectFailure("PURVIEW_TOKEN_SUBJECT_MISMATCH");
        }
        catch (PurviewPolicyException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is FormatException or JsonException)
        {
            throw Failure(
                "PURVIEW_TOKEN_SUBJECT_INVALID",
                "The Purview managed-identity token subject could not be verified.",
                innerException: exception);
        }
        finally
        {
            if (payload is not null)
                CryptographicOperations.ZeroMemory(payload);
        }
    }

    private static byte[] DecodeBase64Url(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized += (normalized.Length % 4) switch
        {
            0 => string.Empty,
            2 => "==",
            3 => "=",
            _ => throw new FormatException(
                "The Purview managed-identity token subject could not be verified.")
        };
        return Convert.FromBase64String(normalized);
    }

    private static bool TryParseCanonicalGuid(string? value, out Guid parsed)
    {
        if (!Guid.TryParse(value, out parsed) ||
            parsed == Guid.Empty ||
            !string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal))
        {
            parsed = Guid.Empty;
            return false;
        }

        return true;
    }

    private static PurviewPolicyException SubjectFailure(string code) =>
        Failure(
            code,
            "The Purview managed-identity token subject could not be verified.");

    private static bool IsTransient(Exception exception)
    {
        if (exception is RequestFailedException requestFailed
            && (requestFailed.Status is 408 or 429 || requestFailed.Status >= 500))
        {
            return true;
        }

        return exception.InnerException is not null && IsTransient(exception.InnerException);
    }

    private static PurviewPolicyException Failure(
        string code,
        string message,
        bool isTransient = false,
        Exception? innerException = null) =>
        new(code, message, isTransient, innerException);

    private sealed record RuntimeIdentityBinding(
        string? ManagedIdentityClientId,
        Guid? PrincipalObjectId);
}
