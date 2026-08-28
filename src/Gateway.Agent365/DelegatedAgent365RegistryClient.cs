using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

/// <summary>
/// Uses the signed-in administrator's delegated Microsoft Graph token for the
/// preview Agent 365 Registry boundary. The token is process-local and is never
/// persisted, queued, or logged.
/// </summary>
internal sealed class DelegatedAgent365RegistryClient : IAgent365DelegatedRegistryClient
{
    private static readonly TimeSpan[] DefaultVerificationDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
        TimeSpan.FromSeconds(12),
        TimeSpan.FromSeconds(16)
    ];

    private static readonly TimeSpan[] DefaultCreateRetryDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8)
    ];

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly HttpClient _httpClient;
    private readonly IAgent365DelegatedTokenProvider _tokenProvider;
    private readonly string _originatingStore;
    private readonly Guid _managerApplicationId;
    private readonly IReadOnlyList<TimeSpan> _verificationDelays;
    private readonly IReadOnlyList<TimeSpan> _createRetryDelays;

    public DelegatedAgent365RegistryClient(
        IHttpClientFactory httpClientFactory,
        IAgent365DelegatedTokenProvider tokenProvider,
        IOptions<Agent365Options> options)
        : this(
            httpClientFactory.CreateClient(nameof(DelegatedAgent365RegistryClient)),
            tokenProvider,
            options.Value.RegistryOriginatingStore,
            options.Value.RegistryManagerApplicationId,
            verificationDelays: null,
            createRetryDelays: null)
    {
    }

    internal DelegatedAgent365RegistryClient(
        HttpClient httpClient,
        IAgent365DelegatedTokenProvider tokenProvider,
        string originatingStore,
        string managerApplicationId,
        IReadOnlyList<TimeSpan>? verificationDelays = null,
        IReadOnlyList<TimeSpan>? createRetryDelays = null)
    {
        _httpClient = httpClient;
        _tokenProvider = tokenProvider;
        _originatingStore = originatingStore;
        if (!TryParseNonEmptyGuid(managerApplicationId, out _managerApplicationId))
            throw new InvalidOperationException("The Agent 365 Registry manager application ID is invalid.");
        _verificationDelays = verificationDelays?.ToArray() ?? DefaultVerificationDelays;
        _createRetryDelays = createRetryDelays?.ToArray() ?? DefaultCreateRetryDelays;
    }

    public async Task<string> CreateAsync(
        Agent365DelegatedRegistryRequest request,
        CancellationToken cancellationToken)
    {
        ValidateRequest(request);
        for (var attemptIndex = 0; attemptIndex < _createRetryDelays.Count; attemptIndex++)
        {
            var delay = _createRetryDelays[attemptIndex];
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            var token = await GetTokenAsync(cancellationToken);
            using var httpRequest = CreateRequest(
                HttpMethod.Post,
                "beta/copilot/agentRegistrations",
                token,
                new
                {
                    id = request.PlannedRegistrationId.ToString("D"),
                    displayName = request.DisplayName,
                    description = request.Description,
                    ownerIds = new[] { request.OwnerObjectId.ToString("D") },
                    sourceAgentId = request.SourceAgentId,
                    originatingStore = _originatingStore,
                    agentIdentityId = request.AgentIdentityObjectId.ToString("D"),
                    agentIdentityBlueprintId = request.BlueprintClientId.ToString("D"),
                    managedByAppId = _managerApplicationId.ToString("D"),
                    createdBy = request.CreatedByObjectId.ToString("D"),
                    sourceCreatedDateTime = request.SourceCreatedAtUtc,
                    sourceLastModifiedDateTime = request.SourceLastModifiedAtUtc
                });

            HttpResponseMessage response;
            try
            {
                response = await _httpClient.SendAsync(
                    httpRequest,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken);
            }
            catch (OperationCanceledException exception) when (cancellationToken.IsCancellationRequested)
            {
                throw AmbiguousCreate(exception);
            }
            catch (TaskCanceledException exception)
            {
                if (attemptIndex + 1 < _createRetryDelays.Count)
                    continue;
                throw AmbiguousCreate(exception);
            }
            catch (HttpRequestException exception)
            {
                if (attemptIndex + 1 < _createRetryDelays.Count)
                    continue;
                throw AmbiguousCreate(exception);
            }

            using (response)
            {
                if (IsCliRetryable(response.StatusCode) &&
                    attemptIndex + 1 < _createRetryDelays.Count)
                    continue;

                if (response.IsSuccessStatusCode)
                {
                    var returnedId = await ReadRegistrationIdAsync(response, cancellationToken);
                    return returnedId ?? request.PlannedRegistrationId.ToString("D");
                }

                if (response.StatusCode == HttpStatusCode.Conflict)
                {
                    var existingId = await ReadRegistrationIdAsync(response, cancellationToken);
                    if (IsSafeRegistrationId(existingId))
                        return existingId!;

                    throw Failure(
                        ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                        "The Agent 365 Registry reported an existing source Agent ID without returning its Registry identifier.",
                        mutationMayHaveOccurred: true);
                }

                throw Failure(
                    MapCreateFailureCode(response.StatusCode),
                    MapCreateFailureSummary(response.StatusCode),
                    mutationMayHaveOccurred: IsAmbiguousCreateStatus(response.StatusCode),
                    isTransient: IsTransient(response.StatusCode));
            }
        }

        throw AmbiguousCreate();
    }

    private static async Task<string?> ReadRegistrationIdAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var record = await JsonSerializer.DeserializeAsync<DelegatedRegistryRecord>(
                stream,
                JsonOptions,
                cancellationToken);
            return IsSafeRegistrationId(record?.Id) ? record!.Id : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public async Task VerifyAsync(
        string agent365RegistrationId,
        Agent365DelegatedRegistryRequest request,
        CancellationToken cancellationToken)
    {
        ValidateRequest(request);
        if (!TryParseNonEmptyGuid(agent365RegistrationId, out var registrationId))
        {
            throw Failure(
                ErrorCodes.AGENT365_REGISTRY_REQUEST_REJECTED,
                "The Agent 365 Registry identifier is invalid.",
                mutationMayHaveOccurred: false);
        }

        foreach (var delay in _verificationDelays)
        {
            if (delay > TimeSpan.Zero)
            {
                try
                {
                    await Task.Delay(delay, cancellationToken);
                }
                catch (OperationCanceledException exception)
                    when (cancellationToken.IsCancellationRequested)
                {
                    throw Failure(
                        ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
                        "Agent 365 Registry verification was interrupted before it completed.",
                        mutationMayHaveOccurred: false,
                        isTransient: true,
                        innerException: exception);
                }
            }

            var result = await TryReadAsync(registrationId, cancellationToken);
            if (result.Retry)
                continue;

            VerifyRecord(result.Record, registrationId, request);
            return;
        }

        throw Failure(
            ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
            "The Agent 365 Registry record isn't available for verification yet.",
            mutationMayHaveOccurred: false,
            isTransient: true);
    }

    private async Task<RegistryReadResult> TryReadAsync(
        Guid registrationId,
        CancellationToken cancellationToken)
    {
        var token = await GetTokenAsync(cancellationToken);
        using var request = CreateRequest(
            HttpMethod.Get,
            $"beta/copilot/agentRegistrations/{registrationId:D}",
            token,
            body: null);

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
        }
        catch (OperationCanceledException exception) when (cancellationToken.IsCancellationRequested)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
                "Agent 365 Registry verification was interrupted before it completed.",
                mutationMayHaveOccurred: false,
                isTransient: true,
                innerException: exception);
        }
        catch (TaskCanceledException)
        {
            return RegistryReadResult.Retryable();
        }
        catch (HttpRequestException)
        {
            return RegistryReadResult.Retryable();
        }

        using (response)
        {
            if (response.StatusCode == HttpStatusCode.NotFound || IsTransient(response.StatusCode))
                return RegistryReadResult.Retryable();

            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                throw Failure(
                    ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                    "The signed-in administrator cannot read the Agent 365 Registry record.",
                    mutationMayHaveOccurred: false);
            }

            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw Failure(
                    ErrorCodes.AGENT365_REGISTRY_REQUEST_REJECTED,
                    "The Agent 365 Registry rejected the verification request.",
                    mutationMayHaveOccurred: false);
            }

            try
            {
                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
                var record = await JsonSerializer.DeserializeAsync<DelegatedRegistryRecord>(
                    stream,
                    JsonOptions,
                    cancellationToken);
                return RegistryReadResult.Found(record);
            }
            catch (OperationCanceledException exception)
                when (cancellationToken.IsCancellationRequested)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
                    "Agent 365 Registry verification was interrupted before it completed.",
                    mutationMayHaveOccurred: false,
                    isTransient: true,
                    innerException: exception);
            }
            catch (JsonException exception)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    "The Agent 365 Registry returned an invalid verification response.",
                    mutationMayHaveOccurred: false,
                    innerException: exception);
            }
        }
    }

    private async Task<string> GetTokenAsync(CancellationToken cancellationToken)
    {
        try
        {
            var token = await _tokenProvider.GetTokenAsync(cancellationToken);
            if (string.IsNullOrWhiteSpace(token))
            {
                throw Failure(
                    ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                    "A delegated Microsoft Graph token is required for Agent 365 registration.",
                    mutationMayHaveOccurred: false);
            }

            return token;
        }
        catch (OperationCanceledException exception) when (cancellationToken.IsCancellationRequested)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
                "A delegated Microsoft Graph token couldn't be acquired before the request expired.",
                mutationMayHaveOccurred: false,
                isTransient: true,
                innerException: exception);
        }
        catch (Agent365DelegatedRegistryException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw Failure(
                ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                "A delegated Microsoft Graph token couldn't be acquired for Agent 365 registration.",
                mutationMayHaveOccurred: false,
                innerException: exception);
        }
    }

    private static HttpRequestMessage CreateRequest(
        HttpMethod method,
        string path,
        string token,
        object? body)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("OData-Version", "4.0");
        if (body is not null)
            request.Content = JsonContent.Create(body, options: JsonOptions);
        return request;
    }

    private void ValidateRequest(Agent365DelegatedRegistryRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.RequestCorrelationId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.DisplayName) ||
            request.DisplayName.Length > 256 ||
            request.Description?.Length > 2000 ||
            request.PlannedRegistrationId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.SourceAgentId) ||
            request.SourceAgentId.Length > 256 ||
            request.OwnerObjectId == Guid.Empty ||
            request.CreatedByObjectId == Guid.Empty ||
            request.AgentIdentityObjectId == Guid.Empty ||
            request.BlueprintClientId == Guid.Empty ||
            request.SourceCreatedAtUtc == default ||
            request.SourceLastModifiedAtUtc == default ||
            request.SourceLastModifiedAtUtc < request.SourceCreatedAtUtc ||
            string.IsNullOrWhiteSpace(_originatingStore) ||
            _originatingStore.Length > 256)
        {
            throw Failure(
                ErrorCodes.AGENT365_REGISTRY_REQUEST_REJECTED,
                "The Agent 365 Registry request is invalid.",
                mutationMayHaveOccurred: false);
        }
    }

    private static void VerifyRecord(
        DelegatedRegistryRecord? record,
        Guid expectedRegistrationId,
        Agent365DelegatedRegistryRequest request)
    {
        var ownerIds = record?.OwnerIds ?? [];
        if (record is null ||
            !TryParseNonEmptyGuid(record.Id, out var actualRegistrationId) ||
            actualRegistrationId != expectedRegistrationId ||
            !string.Equals(record.SourceAgentId, request.SourceAgentId, StringComparison.Ordinal) ||
            !TryParseNonEmptyGuid(record.AgentIdentityId, out var agentIdentityId) ||
            agentIdentityId != request.AgentIdentityObjectId ||
            !TryParseNonEmptyGuid(record.AgentIdentityBlueprintId, out var blueprintClientId) ||
            blueprintClientId != request.BlueprintClientId ||
            !ownerIds.Any(value =>
                TryParseNonEmptyGuid(value, out var ownerId) && ownerId == request.OwnerObjectId) ||
            !TryParseNonEmptyGuid(record.CreatedBy, out var createdBy) ||
            createdBy != request.CreatedByObjectId)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                "The Agent 365 Registry record doesn't match the expected agent identity mapping.",
                mutationMayHaveOccurred: false);
        }
    }

    private static bool IsTransient(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.RequestTimeout or
            HttpStatusCode.TooManyRequests ||
        (int)statusCode >= 500;

    private static bool IsCliRetryable(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.BadGateway or
            HttpStatusCode.ServiceUnavailable or
            HttpStatusCode.GatewayTimeout;

    private static bool IsAmbiguousCreateStatus(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests ||
        (int)statusCode >= 500;

    private static string MapCreateFailureCode(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
            ? ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED
            : IsTransient(statusCode)
                ? ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT
                : ErrorCodes.AGENT365_REGISTRY_REQUEST_REJECTED;

    private static string MapCreateFailureSummary(HttpStatusCode statusCode) =>
        statusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
            ? "The signed-in administrator cannot create the Agent 365 Registry record."
            : IsTransient(statusCode)
                ? "The Agent 365 Registry create outcome is unknown and requires reconciliation."
                : "The Agent 365 Registry rejected the create request.";

    private static bool TryParseNonEmptyGuid(string? value, out Guid parsed) =>
        Guid.TryParse(value, out parsed) && parsed != Guid.Empty;

    private static bool IsSafeRegistrationId(string? value) =>
        TryParseNonEmptyGuid(value, out _);

    private static Agent365DelegatedRegistryException AmbiguousCreate(Exception? exception = null) =>
        Failure(
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
            "The Agent 365 Registry create outcome is unknown and requires exact-ID reconciliation.",
            mutationMayHaveOccurred: true,
            isTransient: true,
            innerException: exception);

    private static Agent365DelegatedRegistryException Failure(
        string errorCode,
        string safeSummary,
        bool mutationMayHaveOccurred,
        bool isTransient = false,
        Exception? innerException = null) =>
        new(errorCode, safeSummary, mutationMayHaveOccurred, isTransient, innerException);

    private sealed record DelegatedRegistryRecord
    {
        public string? Id { get; init; }
        public string? SourceAgentId { get; init; }
        public string? AgentIdentityId { get; init; }
        public string? AgentIdentityBlueprintId { get; init; }
        public List<string>? OwnerIds { get; init; }
        public string? CreatedBy { get; init; }
    }

    private sealed record RegistryReadResult(bool Retry, DelegatedRegistryRecord? Record)
    {
        public static RegistryReadResult Retryable() => new(true, null);
        public static RegistryReadResult Found(DelegatedRegistryRecord? record) => new(false, record);
    }
}
