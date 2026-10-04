using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure;
using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

internal sealed class AgentIdentityTokenProvider :
    IAgent365ObservabilityTokenProvider, IAgent365PurviewTokenProvider
{
    internal const string TokenExchangeAudience = "api://AzureADTokenExchange";
    internal const string TokenExchangeScope = $"{TokenExchangeAudience}/.default";
    internal const string ObservabilityAudience = "9b975845-388f-4429-889e-eab1ef63949c";
    internal const string ObservabilityScope = $"{ObservabilityAudience}/.default";
    internal const string ObservabilityRole = "Agent365.Observability.OtelWrite";

    private const string ClientAssertionType =
        "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";
    private const long FederatedCredentialPropagationErrorCode = 70021;

    private static readonly ValidatedResourceTokenRequest ObservabilityResource = new(
        ObservabilityScope,
        [ObservabilityAudience, $"api://{ObservabilityAudience}"],
        [ObservabilityRole],
        "MissingOtelWriteRole");

    private static readonly ValidatedResourceTokenRequest PurviewResource = new(
        "https://graph.microsoft.com/.default",
        ["00000003-0000-0000-c000-000000000000", "https://graph.microsoft.com"],
        ["Content.Process.User", "ProtectionScopes.Compute.User"],
        "MissingPurviewRoles");

    public ValueTask<AccessToken> GetPurviewTokenAsync(string agentIdentityClientId,
        string blueprintClientId, string expectedTenantId, CancellationToken cancellationToken) =>
        GetResourceTokenCoreAsync(agentIdentityClientId, blueprintClientId, expectedTenantId,
            PurviewResource, cancellationToken);

    private static readonly TimeSpan RefreshBeforeExpiry = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan MinimumTokenLifetime = TimeSpan.FromMinutes(1);

    private readonly ConcurrentDictionary<TokenCacheKey, CachedAccessToken> _cache = new();
    private readonly ConcurrentDictionary<TokenCacheKey, SemaphoreSlim> _cacheLocks = new();
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IReadOnlyDictionary<Guid, string> _blueprintClientSecrets;
    private readonly string? _runtimeCredentialDirectory;

    public AgentIdentityTokenProvider(
        IOptions<Agent365Options> options, IHttpClientFactory httpClientFactory)
    {
        _httpClientFactory = httpClientFactory;
        _runtimeCredentialDirectory = options.Value.RuntimeBlueprintCredentialDirectory;
        _blueprintClientSecrets = options.Value.BlueprintClientSecrets.ToDictionary(
            pair => ParseRequiredGuid(pair.Key, "InvalidBlueprintCredentialId"),
            pair => !string.IsNullOrWhiteSpace(pair.Value)
                ? pair.Value.Trim()
                : throw new Agent365ObservabilityConfigurationException("EmptyBlueprintCredential"));
    }

    public ValueTask<AccessToken> GetTokenAsync(
        string agentIdentityClientId,
        string blueprintClientId,
        string expectedTenantId,
        CancellationToken cancellationToken)
    {
        return GetResourceTokenCoreAsync(
            agentIdentityClientId,
            blueprintClientId,
            expectedTenantId,
            ObservabilityResource,
            cancellationToken);
    }

    private async ValueTask<AccessToken> GetResourceTokenCoreAsync(
        string agentIdentityClientId,
        string blueprintClientId,
        string expectedTenantId,
        ValidatedResourceTokenRequest resource,
        CancellationToken cancellationToken)
    {
        var agentIdentityId = ParseRequiredGuid(
            agentIdentityClientId,
            "InvalidAgentIdentityClientId");
        var blueprintId = ParseRequiredGuid(
            blueprintClientId,
            "InvalidBlueprintClientId");
        var tenantId = ParseRequiredGuid(expectedTenantId, "InvalidTenantId");
        var cacheKey = new TokenCacheKey(
            tenantId,
            blueprintId,
            agentIdentityId,
            resource.ResourceScope);

        if (TryGetCachedToken(cacheKey, out var cachedToken))
        {
            ValidateAgentIdentityToken(cachedToken.Token, agentIdentityId, tenantId, resource);
            return cachedToken;
        }

        var cacheLock = _cacheLocks.GetOrAdd(cacheKey, static _ => new SemaphoreSlim(1, 1));
        await cacheLock.WaitAsync(cancellationToken);
        try
        {
            if (TryGetCachedToken(cacheKey, out cachedToken))
            {
                ValidateAgentIdentityToken(cachedToken.Token, agentIdentityId, tenantId, resource);
                return cachedToken;
            }

            var freshToken = await AcquireAgentIdentityTokenAsync(
                tenantId,
                blueprintId,
                agentIdentityId,
                resource,
                cancellationToken);
            _cache[cacheKey] = new CachedAccessToken(freshToken);
            return freshToken;
        }
        finally
        {
            cacheLock.Release();
        }
    }

    private bool TryGetCachedToken(TokenCacheKey key, out AccessToken token)
    {
        if (_cache.TryGetValue(key, out var cached)
            && cached.Token.ExpiresOn > DateTimeOffset.UtcNow.Add(RefreshBeforeExpiry))
        {
            token = cached.Token;
            return true;
        }

        token = default;
        return false;
    }

    private async Task<AccessToken> AcquireAgentIdentityTokenAsync(
        Guid tenantId,
        Guid blueprintClientId,
        Guid agentIdentityClientId,
        ValidatedResourceTokenRequest resource,
        CancellationToken cancellationToken)
    {
        var tenantTokenEndpoint = new Uri(
            $"https://login.microsoftonline.com/{tenantId:D}/oauth2/v2.0/token");

        // Every blueprint authenticates with its own bootstrap or worker-created credential.
        var savedCredential = RuntimeBlueprintCredentialStore.Read(_runtimeCredentialDirectory, tenantId, blueprintClientId);
        var blueprintSecret = _blueprintClientSecrets.GetValueOrDefault(blueprintClientId) ?? savedCredential?.Secret;
        if (string.IsNullOrWhiteSpace(blueprintSecret))
            throw new Agent365ObservabilityConfigurationException("MissingRuntimeBlueprintCredential");
        var blueprintToken = await RequestTokenAsync(
            tenantTokenEndpoint,
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["client_id"] = blueprintClientId.ToString("D"),
                ["scope"] = TokenExchangeScope,
                ["fmi_path"] = agentIdentityClientId.ToString("D"),
                ["client_secret"] = blueprintSecret,
                ["grant_type"] = "client_credentials"
            },
            "BlueprintToken", cancellationToken,
            allowSecretPropagation: savedCredential is not null && savedCredential.CreatedAtUtc > DateTimeOffset.UtcNow.AddMinutes(-5));

        var agentToken = await RequestTokenAsync(
            tenantTokenEndpoint,
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["client_id"] = agentIdentityClientId.ToString("D"),
                ["scope"] = resource.ResourceScope,
                ["client_assertion_type"] = ClientAssertionType,
                ["client_assertion"] = blueprintToken.Token,
                ["grant_type"] = "client_credentials"
            },
            "AgentIdentityToken",
            cancellationToken);

        var jwtExpiresOn = ValidateAgentIdentityToken(
            agentToken.Token,
            agentIdentityClientId,
            tenantId,
            resource);
        var expiresOn = agentToken.ExpiresOn < jwtExpiresOn
            ? agentToken.ExpiresOn
            : jwtExpiresOn;
        if (expiresOn <= DateTimeOffset.UtcNow.Add(MinimumTokenLifetime))
            throw new Agent365ObservabilityTransientException("AgentIdentityAccessTokenExpired");

        return new AccessToken(agentToken.Token, expiresOn);
    }

    private async Task<OAuthAccessToken> RequestTokenAsync(
        Uri endpoint,
        IReadOnlyDictionary<string, string> formValues,
        string stage,
        CancellationToken cancellationToken,
        bool allowSecretPropagation = false)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new FormUrlEncodedContent(formValues)
        };

        HttpResponseMessage response;
        try
        {
            response = await _httpClientFactory
                .CreateClient(nameof(AgentIdentityTokenProvider))
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        }
        catch (HttpRequestException exception)
        {
            throw new Agent365ObservabilityTransientException($"{stage}NetworkFailure", exception);
        }
        catch (TaskCanceledException exception) when (!cancellationToken.IsCancellationRequested)
        {
            throw new Agent365ObservabilityTransientException($"{stage}Timeout", exception);
        }

        using (response)
        {
            if (IsTransient(response.StatusCode))
                throw new Agent365ObservabilityTransientException(
                    $"{stage}Http{(int)response.StatusCode}");

            if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized
                && await IsCredentialPropagationErrorAsync(response, allowSecretPropagation, cancellationToken))
            {
                throw new Agent365ObservabilityTransientException(
                    $"{stage}FederatedCredentialPropagation");
            }

            if (response.StatusCode != HttpStatusCode.OK)
                throw new Agent365ObservabilityConfigurationException(
                    $"{stage}Http{(int)response.StatusCode}");

            OAuthTokenResponse? payload;
            try
            {
                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
                payload = await JsonSerializer.DeserializeAsync<OAuthTokenResponse>(
                    stream,
                    cancellationToken: cancellationToken);
            }
            catch (JsonException exception)
            {
                throw new Agent365ObservabilityTransientException(
                    $"{stage}InvalidResponse",
                    exception);
            }

            if (payload is null || string.IsNullOrWhiteSpace(payload.AccessToken))
                throw new Agent365ObservabilityTransientException($"{stage}EmptyAccessToken");

            if (payload.ExpiresInSeconds <= 0)
                throw new Agent365ObservabilityTransientException($"{stage}InvalidExpiration");

            DateTimeOffset expiresOn;
            try
            {
                expiresOn = DateTimeOffset.UtcNow.AddSeconds(payload.ExpiresInSeconds);
            }
            catch (ArgumentOutOfRangeException exception)
            {
                throw new Agent365ObservabilityTransientException(
                    $"{stage}InvalidExpiration",
                    exception);
            }

            if (expiresOn <= DateTimeOffset.UtcNow.Add(MinimumTokenLifetime))
                throw new Agent365ObservabilityTransientException($"{stage}TokenExpired");

            return new OAuthAccessToken(payload.AccessToken, expiresOn);
        }
    }

    internal static async Task<bool> IsCredentialPropagationErrorAsync(
        HttpResponseMessage response,
        bool allowSecretPropagation,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var payload = await JsonSerializer.DeserializeAsync<OAuthErrorResponse>(
                stream,
                cancellationToken: cancellationToken);
            return payload is not null
                && string.Equals(payload.Error, "invalid_client", StringComparison.Ordinal)
                && ((payload.ErrorCodes ?? []).Contains(FederatedCredentialPropagationErrorCode)
                    || (allowSecretPropagation && (payload.ErrorCodes ?? []).Contains(7000215)));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is JsonException or NotSupportedException or IOException or HttpRequestException)
        {
            return false;
        }
    }

    private static DateTimeOffset ValidateAgentIdentityToken(
        string token,
        Guid expectedAgentIdentityClientId,
        Guid expectedTenantId,
        ValidatedResourceTokenRequest resource)
    {
        using var payload = ReadJwtPayload(token, "AgentIdentityAccessTokenNotJwt");
        var root = payload.RootElement;

        if (!resource.AllowedAudiences.Any(audience => AudienceContains(root, audience)))
        {
            throw new Agent365ObservabilityConfigurationException("InvalidAudience");
        }

        ValidateApplicationId(root, expectedAgentIdentityClientId, "AgentIdentityMismatch");
        ValidateTenant(root, expectedTenantId, "TenantIdentityMismatch");

        if (GetOptionalString(root, "scp") is { Length: > 0 })
            throw new Agent365ObservabilityConfigurationException("DelegatedTokenNotAllowed");

        var tokenRoles = root.TryGetProperty("roles", out var roles)
            && roles.ValueKind == JsonValueKind.Array
                ? roles.EnumerateArray()
                    .Where(role => role.ValueKind == JsonValueKind.String)
                    .Select(role => role.GetString()!)
                    .ToHashSet(StringComparer.Ordinal)
                : [];
        if (resource.RequiredApplicationRoles.Any(role => !tokenRoles.Contains(role)))
        {
            throw new Agent365ObservabilityConfigurationException(resource.MissingRoleErrorCode);
        }

        return ValidateExpiration(root, "MissingExpiration");
    }

    private static JsonDocument ReadJwtPayload(string token, string errorCode)
    {
        try
        {
            var segments = token.Split('.');
            if (segments.Length != 3)
                throw new Agent365ObservabilityConfigurationException(errorCode);

            return JsonDocument.Parse(DecodeBase64Url(segments[1]));
        }
        catch (Agent365ObservabilityExportException)
        {
            throw;
        }
        catch (Exception exception) when (exception is FormatException or JsonException)
        {
            throw new Agent365ObservabilityConfigurationException(errorCode, exception);
        }
    }

    private static bool AudienceContains(JsonElement payload, string expectedAudience)
    {
        if (!payload.TryGetProperty("aud", out var audience))
            return false;

        return audience.ValueKind switch
        {
            JsonValueKind.String => string.Equals(
                audience.GetString(),
                expectedAudience,
                StringComparison.OrdinalIgnoreCase),
            JsonValueKind.Array => audience.EnumerateArray().Any(value =>
                value.ValueKind == JsonValueKind.String
                && string.Equals(
                    value.GetString(),
                    expectedAudience,
                    StringComparison.OrdinalIgnoreCase)),
            _ => false
        };
    }

    private static void ValidateApplicationId(
        JsonElement payload,
        Guid expectedClientId,
        string errorCode)
    {
        var applicationId = GetOptionalString(payload, "appid")
            ?? GetOptionalString(payload, "azp");
        if (!Guid.TryParse(applicationId, out var parsed) || parsed != expectedClientId)
            throw new Agent365ObservabilityConfigurationException(errorCode);
    }

    private static void ValidateTenant(
        JsonElement payload,
        Guid expectedTenantId,
        string errorCode)
    {
        ValidateGuidClaim(payload, "tid", expectedTenantId, errorCode);
    }

    private static void ValidateGuidClaim(
        JsonElement payload,
        string claimName,
        Guid expectedValue,
        string errorCode)
    {
        var value = GetOptionalString(payload, claimName);
        if (!Guid.TryParse(value, out var parsed) || parsed != expectedValue)
            throw new Agent365ObservabilityConfigurationException(errorCode);
    }

    private static DateTimeOffset ValidateExpiration(JsonElement payload, string missingErrorCode)
    {
        if (!payload.TryGetProperty("exp", out var expiration)
            || expiration.ValueKind != JsonValueKind.Number
            || !expiration.TryGetInt64(out var seconds))
        {
            throw new Agent365ObservabilityConfigurationException(missingErrorCode);
        }

        DateTimeOffset expiresOn;
        try
        {
            expiresOn = DateTimeOffset.FromUnixTimeSeconds(seconds);
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw new Agent365ObservabilityConfigurationException(missingErrorCode, exception);
        }

        if (expiresOn <= DateTimeOffset.UtcNow.Add(MinimumTokenLifetime))
            throw new Agent365ObservabilityTransientException("AccessTokenExpired");

        return expiresOn;
    }

    private static byte[] DecodeBase64Url(string value)
    {
        var padded = value.Replace('-', '+').Replace('_', '/');
        padded = (padded.Length % 4) switch
        {
            0 => padded,
            2 => padded + "==",
            3 => padded + "=",
            _ => throw new FormatException("Invalid base64url value.")
        };

        return Convert.FromBase64String(padded);
    }

    private static string? GetOptionalString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.String
                ? property.GetString()
                : null;
    }

    private static Guid ParseRequiredGuid(string? value, string errorCode)
    {
        if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
            throw new Agent365ObservabilityConfigurationException(errorCode);

        return parsed;
    }

    private static bool IsTransient(HttpStatusCode statusCode)
    {
        var value = (int)statusCode;
        return value is 408 or 429 || value >= 500;
    }

    private static bool IsTransient(Exception exception)
    {
        if (exception is RequestFailedException requestFailed
            && IsTransient((HttpStatusCode)requestFailed.Status))
        {
            return true;
        }

        return exception.InnerException is not null && IsTransient(exception.InnerException);
    }

    private readonly record struct TokenCacheKey(
        Guid TenantId,
        Guid BlueprintClientId,
        Guid AgentIdentityClientId,
        string ResourceScope);

    private readonly record struct CachedAccessToken(AccessToken Token);

    private readonly record struct OAuthAccessToken(string Token, DateTimeOffset ExpiresOn);

    private sealed record ValidatedResourceTokenRequest(
        string ResourceScope,
        string[] AllowedAudiences,
        string[] RequiredApplicationRoles,
        string MissingRoleErrorCode);

    private sealed class OAuthTokenResponse
    {
        [JsonPropertyName("access_token")]
        public string? AccessToken { get; init; }

        [JsonPropertyName("expires_in")]
        [JsonNumberHandling(JsonNumberHandling.AllowReadingFromString)]
        public long ExpiresInSeconds { get; init; }
    }

    private sealed class OAuthErrorResponse
    {
        [JsonPropertyName("error")]
        public string? Error { get; init; }

        [JsonPropertyName("error_codes")]
        public long[]? ErrorCodes { get; init; }
    }
}
