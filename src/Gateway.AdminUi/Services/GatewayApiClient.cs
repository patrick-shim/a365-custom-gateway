using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Services;

public sealed class GatewayApiClient : IGatewayApiClient
{
    private const string CorrelationIdHeader = "X-Correlation-ID";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly HttpClient _httpClient;
    private readonly IGatewayAccessTokenProvider _accessTokenProvider;
    private readonly ILogger<GatewayApiClient> _logger;

    public GatewayApiClient(
        HttpClient httpClient,
        IGatewayAccessTokenProvider accessTokenProvider,
        ILogger<GatewayApiClient> logger)
    {
        _httpClient = httpClient;
        _accessTokenProvider = accessTokenProvider;
        _logger = logger;
    }

    public Task<GatewayHealthStatus> GetHealthAsync(CancellationToken cancellationToken = default) =>
        SendForValueAsync<GatewayHealthStatus>(
            new HttpRequestMessage(HttpMethod.Get, "health"),
            requiresAuthentication: false,
            cancellationToken);

    public Task<GatewayHealthStatus> GetReadinessAsync(CancellationToken cancellationToken = default) =>
        SendForValueAsync<GatewayHealthStatus>(
            new HttpRequestMessage(HttpMethod.Get, "health/ready"),
            requiresAuthentication: false,
            cancellationToken,
            HttpStatusCode.ServiceUnavailable);

    public Task<AgentListResponse> GetAgentsAsync(
        AgentListQuery? query = null,
        CancellationToken cancellationToken = default)
    {
        query ??= new AgentListQuery();
        ValidatePageLimit(query.Limit);

        var parameters = new List<KeyValuePair<string, string?>>
        {
            new("status", NullIfWhiteSpace(query.Status)),
            new("environment", NullIfWhiteSpace(query.Environment)),
            new("search", NullIfWhiteSpace(query.Search)),
            new("limit", query.Limit.ToString(CultureInfo.InvariantCulture)),
            new("cursor", NullIfWhiteSpace(query.Cursor))
        };

        return SendForValueAsync<AgentListResponse>(
            new HttpRequestMessage(HttpMethod.Get, BuildRelativeUri("api/v1/agents", parameters)),
            requiresAuthentication: true,
            cancellationToken);
    }

    public Task<GatewayApiResource<AgentDetailDto>> GetAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        return SendAsync<AgentDetailDto>(
            new HttpRequestMessage(HttpMethod.Get, $"api/v1/agents/{agentId:D}"),
            requiresAuthentication: true,
            cancellationToken);
    }

    public Task<AgentIngressCredentialListResponse> GetAgentIngressCredentialsAsync(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        return SendForValueAsync<AgentIngressCredentialListResponse>(
            new HttpRequestMessage(
                HttpMethod.Get,
                $"api/v1/agents/{agentId:D}/credentials"),
            requiresAuthentication: true,
            cancellationToken);
    }

    public Task<IssueAgentIngressCredentialResponse> IssueAgentIngressCredentialAsync(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        var message = new HttpRequestMessage(
            HttpMethod.Post,
            $"api/v1/agents/{agentId:D}/credentials");

        return SendForValueAsync<IssueAgentIngressCredentialResponse>(
            message,
            requiresAuthentication: true,
            cancellationToken);
    }

    public Task<RevokeAgentIngressCredentialResponse> RevokeAgentIngressCredentialAsync(
        Guid agentId,
        Guid credentialId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));
        EnsureNotEmpty(credentialId, nameof(credentialId));

        var message = new HttpRequestMessage(
            HttpMethod.Delete,
            $"api/v1/agents/{agentId:D}/credentials/{credentialId:D}");

        return SendForValueAsync<RevokeAgentIngressCredentialResponse>(
            message,
            requiresAuthentication: true,
            cancellationToken);
    }

    public Task<AgentIdentityBlueprintListResponse> GetAgentIdentityBlueprintsAsync(
        CancellationToken cancellationToken = default) =>
        SendForValueAsync<AgentIdentityBlueprintListResponse>(
            new HttpRequestMessage(HttpMethod.Get, "api/v1/agent-identity-blueprints"),
            requiresAuthentication: true,
            cancellationToken);

    public Task<PurviewPolicyProfileListResponse> GetPurviewPolicyProfilesAsync(
        CancellationToken cancellationToken = default) =>
        SendForValueAsync<PurviewPolicyProfileListResponse>(
            new HttpRequestMessage(HttpMethod.Get, "api/v1/purview-policy-profiles"),
            requiresAuthentication: true,
            cancellationToken);

    public Task<RegisterAgentResponse> RegisterAgentAsync(
        RegisterAgentRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var message = CreateJsonRequest(HttpMethod.Post, "api/v1/agents", request);

        return SendForValueAsync<RegisterAgentResponse>(message, true, cancellationToken);
    }

    public Task<UpdateFeaturesResponse> UpdateAgentFeaturesAsync(
        Guid agentId,
        UpdateFeaturesRequest request,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));
        ArgumentNullException.ThrowIfNull(request);

        var message = CreateJsonRequest(
            HttpMethod.Patch,
            $"api/v1/agents/{agentId:D}/features",
            request);

        return SendForValueAsync<UpdateFeaturesResponse>(message, true, cancellationToken);
    }

    public Task<AgentStateChangeResponse> EnableAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default) =>
        SendAgentStateChangeAsync(agentId, "enable", cancellationToken);

    public Task<AgentStateChangeResponse> DisableAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default) =>
        SendAgentStateChangeAsync(agentId, "disable", cancellationToken);

    public Task<AsyncOperationResponse> RetryProvisioningAsync(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        var message = new HttpRequestMessage(
            HttpMethod.Post,
            $"api/v1/agents/{agentId:D}:retry-provisioning");

        return SendForValueAsync<AsyncOperationResponse>(message, true, cancellationToken);
    }

    public Task<DeleteAgentResponse> DeleteAgentAsync(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        var message = new HttpRequestMessage(HttpMethod.Delete, $"api/v1/agents/{agentId:D}");

        return SendForValueAsync<DeleteAgentResponse>(message, true, cancellationToken);
    }

    public Task<AuditEventListResponse> GetAgentAuditEventsAsync(
        Guid agentId,
        AuditEventQuery? query = null,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));
        query ??= new AuditEventQuery();
        ValidatePageLimit(query.Limit);

        var parameters = new List<KeyValuePair<string, string?>>
        {
            new("limit", query.Limit.ToString(CultureInfo.InvariantCulture)),
            new("cursor", NullIfWhiteSpace(query.Cursor))
        };

        return SendForValueAsync<AuditEventListResponse>(
            new HttpRequestMessage(
                HttpMethod.Get,
                BuildRelativeUri($"api/v1/agents/{agentId:D}/audit-events", parameters)),
            true,
            cancellationToken);
    }

    public Task<ProvisioningHistoryResponse> GetProvisioningHistoryAsync(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        return SendForValueAsync<ProvisioningHistoryResponse>(
            new HttpRequestMessage(
                HttpMethod.Get,
                $"api/v1/agents/{agentId:D}/provisioning-history"),
            true,
            cancellationToken);
    }

    public Task<OperationStatusDto> GetOperationStatusAsync(
        Guid operationId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(operationId, nameof(operationId));

        return SendForValueAsync<OperationStatusDto>(
            new HttpRequestMessage(HttpMethod.Get, $"api/v1/operations/{operationId:D}"),
            true,
            cancellationToken);
    }

    public Task<CompleteAgent365RegistrationResponse> CompleteAgent365RegistrationAsync(
        Guid operationId,
        CancellationToken cancellationToken = default)
    {
        EnsureNotEmpty(operationId, nameof(operationId));

        return SendForValueAsync<CompleteAgent365RegistrationResponse>(
            new HttpRequestMessage(
                HttpMethod.Post,
                $"api/v1/operations/{operationId:D}:complete-agent365-registration"),
            true,
            cancellationToken);
    }

    public Task<SystemConfigDto> GetSystemConfigAsync(CancellationToken cancellationToken = default) =>
        SendForValueAsync<SystemConfigDto>(
            new HttpRequestMessage(HttpMethod.Get, "api/v1/system/config"),
            true,
            cancellationToken);

    public Task<SystemConfigDto> UpdateSystemConfigAsync(
        UpdateSystemConfigRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var message = CreateJsonRequest(HttpMethod.Patch, "api/v1/system/config", request);

        return SendForValueAsync<SystemConfigDto>(message, true, cancellationToken);
    }

    private async Task<AgentStateChangeResponse> SendAgentStateChangeAsync(
        Guid agentId,
        string action,
        CancellationToken cancellationToken)
    {
        EnsureNotEmpty(agentId, nameof(agentId));

        var message = new HttpRequestMessage(
            HttpMethod.Post,
            $"api/v1/agents/{agentId:D}:{action}");

        return await SendForValueAsync<AgentStateChangeResponse>(message, true, cancellationToken);
    }

    private async Task<T> SendForValueAsync<T>(
        HttpRequestMessage request,
        bool requiresAuthentication,
        CancellationToken cancellationToken,
        params HttpStatusCode[] additionalSuccessStatuses)
    {
        var resource = await SendAsync<T>(
            request,
            requiresAuthentication,
            cancellationToken,
            additionalSuccessStatuses);
        return resource.Value;
    }

    private async Task<GatewayApiResource<T>> SendAsync<T>(
        HttpRequestMessage request,
        bool requiresAuthentication,
        CancellationToken cancellationToken,
        params HttpStatusCode[] additionalSuccessStatuses)
    {
        using (request)
        {
            var requestCorrelationId = Guid.NewGuid().ToString("D");
            var safeRequestPath = GetSafeRequestPath(request.RequestUri);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            request.Headers.TryAddWithoutValidation(CorrelationIdHeader, requestCorrelationId);

            if (requiresAuthentication)
            {
                var accessToken = await _accessTokenProvider.GetAccessTokenAsync(cancellationToken);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            }

            HttpResponseMessage response;
            try
            {
                response = await _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken);
            }
            catch (OperationCanceledException exception) when (!cancellationToken.IsCancellationRequested)
            {
                _logger.LogWarning(
                    "Gateway API request timed out. CorrelationId: {CorrelationId}; Method: {Method}; Path: {Path}",
                    requestCorrelationId,
                    request.Method.Method,
                    safeRequestPath);
                throw new GatewayApiTransportException(
                    "The Gateway API request timed out.",
                    requestCorrelationId,
                    exception);
            }
            catch (HttpRequestException exception)
            {
                _logger.LogWarning(
                    "Gateway API transport failure. CorrelationId: {CorrelationId}; Method: {Method}; Path: {Path}; ErrorType: {ErrorType}",
                    requestCorrelationId,
                    request.Method.Method,
                    safeRequestPath,
                    exception.GetType().Name);
                throw new GatewayApiTransportException(
                    "The Gateway API could not be reached.",
                    requestCorrelationId,
                    exception);
            }

            using (response)
            {
                var responseCorrelationId = GetHeader(response, CorrelationIdHeader) ?? requestCorrelationId;

                if (!response.IsSuccessStatusCode &&
                    !additionalSuccessStatuses.Contains(response.StatusCode))
                {
                    var apiException = await CreateApiExceptionAsync(
                        response,
                        responseCorrelationId,
                        cancellationToken);

                    _logger.Log(
                        (int)response.StatusCode >= 500 ? LogLevel.Warning : LogLevel.Information,
                        "Gateway API rejected a request. CorrelationId: {CorrelationId}; Method: {Method}; Path: {Path}; StatusCode: {StatusCode}; ErrorCode: {ErrorCode}",
                        apiException.CorrelationId,
                        request.Method.Method,
                        safeRequestPath,
                        (int)response.StatusCode,
                        apiException.ErrorCode ?? "unavailable");

                    throw apiException;
                }

                try
                {
                    var value = await response.Content.ReadFromJsonAsync<T>(JsonOptions, cancellationToken);
                    if (value is null)
                    {
                        throw new GatewayApiProtocolException(
                            "The Gateway API returned an empty response.",
                            responseCorrelationId);
                    }

                    return new GatewayApiResource<T>(
                        value,
                        GetHeader(response, "ETag"),
                        responseCorrelationId);
                }
                catch (Exception exception) when (exception is JsonException or NotSupportedException)
                {
                    _logger.LogWarning(
                        "Gateway API protocol failure. CorrelationId: {CorrelationId}; Method: {Method}; Path: {Path}; ErrorType: {ErrorType}",
                        responseCorrelationId,
                        request.Method.Method,
                        safeRequestPath,
                        exception.GetType().Name);
                    throw new GatewayApiProtocolException(
                        "The Gateway API returned an unexpected response.",
                        responseCorrelationId,
                        exception);
                }
            }
        }
    }

    private static async Task<GatewayApiException> CreateApiExceptionAsync(
        HttpResponseMessage response,
        string correlationId,
        CancellationToken cancellationToken)
    {
        ProblemDocument? problem = null;

        try
        {
            problem = await response.Content.ReadFromJsonAsync<ProblemDocument>(
                JsonOptions,
                cancellationToken);
        }
        catch (Exception exception) when (exception is JsonException or NotSupportedException)
        {
            // Non-Problem-Details bodies are deliberately not surfaced.
        }

        var extensions = problem?.Extensions;
        var errorCode = ReadStringExtension(extensions, "errorCode") ??
            ReadStringExtension(extensions, "code");
        var problemCorrelationId = ReadStringExtension(extensions, "correlationId");
        var challengeType = ReadStringExtension(extensions, "challengeType");
        var hasClaimsChallenge =
            ReadBooleanExtension(extensions, "claimsChallenge") ||
            string.Equals(challengeType, "claims_challenge", StringComparison.Ordinal) ||
            HasBearerChallengeParameter(response, "insufficient_claims");
        var requiresUserInteraction = response.StatusCode == HttpStatusCode.Unauthorized &&
            (string.Equals(
                 errorCode,
                 ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                 StringComparison.Ordinal) ||
             string.Equals(challengeType, "consent_required", StringComparison.Ordinal) ||
             hasClaimsChallenge ||
             HasBearerChallengeParameter(response, "insufficient_scope"));

        return new GatewayApiException(
            response.StatusCode,
            problem?.Title ?? GetDefaultTitle(response.StatusCode),
            problem?.Detail,
            problem?.Type,
            problem?.Instance,
            errorCode,
            problemCorrelationId ?? correlationId,
            ReadValidationErrors(extensions),
            GetRetryAfter(response),
            requiresUserInteraction,
            hasClaimsChallenge,
            ReadStringArrayExtension(extensions, "requiredScopes"));
    }

    private static HttpRequestMessage CreateJsonRequest<T>(
        HttpMethod method,
        string relativeUri,
        T value) =>
        new(method, relativeUri)
        {
            Content = JsonContent.Create(value, options: JsonOptions)
        };

    private static string BuildRelativeUri(
        string path,
        IEnumerable<KeyValuePair<string, string?>> parameters)
    {
        var query = string.Join(
            "&",
            parameters
                .Where(parameter => parameter.Value is not null)
                .Select(parameter =>
                    $"{Uri.EscapeDataString(parameter.Key)}={Uri.EscapeDataString(parameter.Value!)}"));

        return query.Length == 0 ? path : $"{path}?{query}";
    }

    private static string? GetHeader(HttpResponseMessage response, string name)
    {
        if (response.Headers.TryGetValues(name, out var values))
        {
            return values.FirstOrDefault();
        }

        return response.Content.Headers.TryGetValues(name, out values)
            ? values.FirstOrDefault()
            : null;
    }

    private static string GetSafeRequestPath(Uri? requestUri)
    {
        if (requestUri is null)
        {
            return "/";
        }

        var value = requestUri.IsAbsoluteUri
            ? requestUri.AbsolutePath
            : requestUri.OriginalString.Split('?', 2)[0];

        return string.IsNullOrWhiteSpace(value) ? "/" : value;
    }

    private static TimeSpan? GetRetryAfter(HttpResponseMessage response)
    {
        if (response.Headers.RetryAfter?.Delta is { } delta)
        {
            return delta;
        }

        if (response.Headers.RetryAfter?.Date is { } date)
        {
            var duration = date - DateTimeOffset.UtcNow;
            return duration > TimeSpan.Zero ? duration : TimeSpan.Zero;
        }

        return null;
    }

    private static string GetDefaultTitle(HttpStatusCode statusCode) => statusCode switch
    {
        HttpStatusCode.BadRequest => "The request was invalid.",
        HttpStatusCode.Unauthorized => "Authentication is required.",
        HttpStatusCode.Forbidden => "You are not authorized to perform this action.",
        HttpStatusCode.NotFound => "The requested resource was not found.",
        HttpStatusCode.Conflict => "The request conflicts with the current resource state.",
        HttpStatusCode.PreconditionFailed => "The resource has changed. Refresh and try again.",
        HttpStatusCode.TooManyRequests => "The Gateway API rate limit was reached.",
        _ when (int)statusCode >= 500 => "The Gateway API is temporarily unavailable.",
        _ => "The Gateway API rejected the request."
    };

    private static string? ReadStringExtension(
        IReadOnlyDictionary<string, JsonElement>? extensions,
        string name)
    {
        if (extensions is null || !extensions.TryGetValue(name, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    private static bool ReadBooleanExtension(
        IReadOnlyDictionary<string, JsonElement>? extensions,
        string name) =>
        extensions is not null &&
        extensions.TryGetValue(name, out var value) &&
        value.ValueKind is JsonValueKind.True or JsonValueKind.False &&
        value.GetBoolean();

    private static IReadOnlyList<string> ReadStringArrayExtension(
        IReadOnlyDictionary<string, JsonElement>? extensions,
        string name)
    {
        if (extensions is null ||
            !extensions.TryGetValue(name, out var value) ||
            value.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        return value
            .EnumerateArray()
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Select(item => item!)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
    }

    private static bool HasBearerChallengeParameter(
        HttpResponseMessage response,
        string parameterValue)
    {
        if (!response.Headers.TryGetValues("WWW-Authenticate", out var values))
        {
            return false;
        }

        return values.Any(value =>
            value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) &&
            value.Contains(parameterValue, StringComparison.OrdinalIgnoreCase));
    }

    private static IReadOnlyDictionary<string, string[]> ReadValidationErrors(
        IReadOnlyDictionary<string, JsonElement>? extensions)
    {
        if (extensions is null ||
            !extensions.TryGetValue("errors", out var errors) ||
            errors.ValueKind != JsonValueKind.Object)
        {
            return new Dictionary<string, string[]>();
        }

        var result = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);

        foreach (var property in errors.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.Array)
            {
                result[property.Name] = property.Value
                    .EnumerateArray()
                    .Where(item => item.ValueKind == JsonValueKind.String)
                    .Select(item => item.GetString()!)
                    .ToArray();
            }
            else if (property.Value.ValueKind == JsonValueKind.String)
            {
                result[property.Name] = [property.Value.GetString()!];
            }
        }

        return result;
    }

    private static string? NullIfWhiteSpace(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;

    private static void ValidatePageLimit(int limit)
    {
        if (limit is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit),
                limit,
                "Page size must be between 1 and 100.");
        }
    }

    private static void EnsureNotEmpty(Guid value, string parameterName)
    {
        if (value == Guid.Empty)
        {
            throw new ArgumentException("The identifier cannot be empty.", parameterName);
        }
    }

    private sealed class ProblemDocument
    {
        public string? Type { get; init; }

        public string? Title { get; init; }

        public int? Status { get; init; }

        public string? Detail { get; init; }

        public string? Instance { get; init; }

        [JsonExtensionData]
        public Dictionary<string, JsonElement>? Extensions { get; init; }
    }
}
