using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

public sealed class ObservabilityExporter : IObservabilityExporter
{
    internal const string OfficialHost = "agent365.svc.cloud.microsoft";
    internal const string InstrumentationName = "A365.CustomGateway";

    private const string RedactedInput = "[{\"role\":\"user\",\"content\":\"[REDACTED]\"}]";
    private const string RedactedOutput = "[{\"role\":\"assistant\",\"content\":\"[REDACTED]\"}]";
    private const string RedactedToolData = "{\"content\":\"[REDACTED]\"}";

    private const string UnspecifiedReason = "unspecified";
    private const int MaxSinkReasonLength = 64;

    private static readonly HashSet<string> SupportedOperations = new(StringComparer.Ordinal)
    {
        "invoke_agent",
        "execute_tool",
        "chat",
        "output_messages"
    };

    private readonly ILogger<ObservabilityExporter> _logger;
    private readonly Agent365Options _options;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IAgent365ObservabilityTokenProvider _tokenProvider;

    public ObservabilityExporter(
        ILogger<ObservabilityExporter> logger,
        IOptions<Agent365Options> options,
        IHttpClientFactory httpClientFactory,
        IAgent365ObservabilityTokenProvider tokenProvider)
    {
        _logger = logger;
        _options = options.Value;
        _httpClientFactory = httpClientFactory;
        _tokenProvider = tokenProvider;
    }

    public async Task ExportActivityAsync(
        ObservabilityExportRequest request,
        CancellationToken cancellationToken)
    {
        var tenantId = ParseRequiredGuid(_options.TenantId, "InvalidTenantId");
        var agentIdentityClientId = ParseRequiredGuid(
            request.AgentIdentityClientId,
            "InvalidAgentIdentityClientId");
        var blueprintClientId = ParseRequiredGuid(
            request.BlueprintClientId,
            "InvalidBlueprintClientId");
        var operation = NormalizeOperation(request.SpanType);

        if (!Guid.TryParse(request.TenantUserObjectId, out var userObjectId)
            || userObjectId == Guid.Empty)
        {
            throw new Agent365ObservabilityConfigurationException("MissingUserContext");
        }

        var serverAddress = SanitizeRequired(
            _options.ObservabilityServerAddress,
            "MissingServerAddress",
            255);
        if (_options.ObservabilityServerPort is < 1 or > 65535)
            throw new Agent365ObservabilityConfigurationException("InvalidServerPort");

        AccessToken accessToken = await _tokenProvider.GetTokenAsync(
            agentIdentityClientId.ToString("D"),
            blueprintClientId.ToString("D"),
            tenantId.ToString("D"),
            cancellationToken);

        var rootAttributes = BuildAttributes(
            request,
            "invoke_agent",
            tenantId,
            agentIdentityClientId,
            blueprintClientId,
            serverAddress,
            _options.ObservabilityServerPort);

        var traceId = CreateHexId($"{request.EventId:D}:{request.CorrelationId}", 16);
        var rootSpanId = CreateHexId($"{request.EventId:D}:invoke_agent:root", 8);
        var startTime = NormalizeUtc(request.StartedAtUtc);
        var endTime = NormalizeUtc(request.EndedAtUtc);
        if (endTime < startTime)
            endTime = startTime;

        var spans = new List<OtlpSpanPayload>
        {
            CreateSpan(
                traceId,
                rootSpanId,
                parentSpanId: string.Empty,
                operation: "invoke_agent",
                kind: 1,
                startTime,
                endTime,
                rootAttributes)
        };

        if (operation != "invoke_agent")
        {
            var childAttributes = BuildAttributes(
                request,
                operation,
                tenantId,
                agentIdentityClientId,
                blueprintClientId,
                serverAddress,
                _options.ObservabilityServerPort);
            var childSpanId = CreateHexId($"{request.EventId:D}:{operation}:child", 8);
            spans.Add(CreateSpan(
                traceId,
                childSpanId,
                rootSpanId,
                operation,
                operation is "chat" or "execute_tool" ? 3 : 1,
                startTime,
                endTime,
                childAttributes));
        }

        var payload = new
        {
            resourceSpans = new[]
            {
                new
                {
                    resource = new
                    {
                        attributes = ToOtlpAttributes(new Dictionary<string, string>(StringComparer.Ordinal)
                        {
                            ["service.name"] = InstrumentationName,
                            ["operation.source"] = InstrumentationName
                        })
                    },
                    scopeSpans = new[]
                    {
                        new
                        {
                            scope = new { name = InstrumentationName, version = "1.0.0" },
                            spans
                        }
                    }
                }
            }
        };

        var endpoint = new Uri(
            $"https://{OfficialHost}/observabilityService/tenants/{tenantId:D}/otlp/agents/{agentIdentityClientId:D}/traces?api-version=1");

        using var message = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = JsonContent.Create(payload)
        };
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken.Token);

        HttpResponseMessage response;
        try
        {
            response = await _httpClientFactory
                .CreateClient(nameof(ObservabilityExporter))
                .SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        }
        catch (HttpRequestException exception)
        {
            throw new Agent365ObservabilityTransientException("NetworkFailure", exception);
        }
        catch (TaskCanceledException exception) when (!cancellationToken.IsCancellationRequested)
        {
            throw new Agent365ObservabilityTransientException("ExportTimeout", exception);
        }

        using (response)
        {
            if (IsTransient(response.StatusCode))
            {
                await DelayForRetryAfterAsync(response, cancellationToken);
                throw new Agent365ObservabilityTransientException(
                    $"Http{(int)response.StatusCode}");
            }

            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw new Agent365ObservabilityConfigurationException(
                    $"Http{(int)response.StatusCode}");
            }

            await EnsureExportAcceptedAsync(
                response,
                request.AgentRegistrationId,
                operation,
                cancellationToken);
        }

        _logger.LogInformation(
            "Exported sanitized Agent 365 span for agent {AgentRegistrationId}, operation {Operation}",
            request.AgentRegistrationId,
            operation);
    }

    private static Dictionary<string, string> BuildAttributes(
        ObservabilityExportRequest request,
        string operation,
        Guid tenantId,
        Guid agentIdentityClientId,
        Guid blueprintClientId,
        string serverAddress,
        int serverPort)
    {
        var conversationId = SanitizeOpaqueIdentifier(request.SessionId)
            ?? request.EventId.ToString("D");
        var attributes = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["gen_ai.operation.name"] = operation,
            ["microsoft.tenant.id"] = tenantId.ToString("D"),
            ["gen_ai.agent.id"] = agentIdentityClientId.ToString("D"),
            ["gen_ai.agent.name"] = SanitizeRequired(request.AgentName, "MissingAgentName", 256),
            ["microsoft.a365.agent.blueprint.id"] = blueprintClientId.ToString("D"),
            ["gen_ai.conversation.id"] = conversationId,
            ["microsoft.channel.name"] = "a365-custom-gateway",
            ["correlation.id"] = SanitizeOpaqueIdentifier(request.CorrelationId)
                ?? throw new Agent365ObservabilityConfigurationException("MissingCorrelationId"),
            ["operation.source"] = InstrumentationName
        };

        if (SanitizeOpaqueIdentifier(request.SessionId) is { } sessionId)
            attributes["microsoft.session.id"] = sessionId;

        if (operation is "invoke_agent" or "execute_tool" or "chat")
        {
            attributes["client.address"] = "0.0.0.0";
            attributes["server.address"] = serverAddress;
            attributes["server.port"] = serverPort.ToString(CultureInfo.InvariantCulture);
        }

        switch (operation)
        {
            case "invoke_agent":
                attributes["user.id"] = Guid.Parse(request.TenantUserObjectId!).ToString("D");
                attributes["gen_ai.execution.type"] = "HumanToAgent";
                attributes["gen_ai.input.messages"] = RedactedInput;
                attributes["gen_ai.output.messages"] = RedactedOutput;
                break;
            case "execute_tool":
                attributes["gen_ai.tool.name"] = "external-tool";
                attributes["gen_ai.tool.type"] = "function";
                attributes["gen_ai.tool.call.id"] = request.EventId.ToString("D");
                attributes["gen_ai.tool.call.arguments"] = RedactedToolData;
                attributes["gen_ai.tool.call.result"] = RedactedToolData;
                break;
            case "chat":
                attributes["gen_ai.request.model"] = SanitizeOptional(request.ModelName, 256) ?? "unknown";
                attributes["gen_ai.provider.name"] = SanitizeOptional(request.ModelProvider, 256) ?? "unknown";
                attributes["gen_ai.input.messages"] = RedactedInput;
                attributes["gen_ai.output.messages"] = RedactedOutput;
                break;
            case "output_messages":
                attributes["gen_ai.output.messages"] = RedactedOutput;
                break;
        }

        return attributes;
    }

    private static object[] ToOtlpAttributes(IReadOnlyDictionary<string, string> attributes)
    {
        return attributes
            .Select(attribute => (object)new
            {
                key = attribute.Key,
                value = new { stringValue = attribute.Value }
            })
            .ToArray();
    }

    private static OtlpSpanPayload CreateSpan(
        string traceId,
        string spanId,
        string parentSpanId,
        string operation,
        int kind,
        DateTime startTime,
        DateTime endTime,
        IReadOnlyDictionary<string, string> attributes)
    {
        return new OtlpSpanPayload(
            traceId,
            spanId,
            parentSpanId,
            operation,
            kind,
            ToUnixNanoseconds(startTime),
            ToUnixNanoseconds(endTime),
            new OtlpStatusPayload(1),
            ToOtlpAttributes(attributes));
    }

    // A 200 OK only means Agent 365 processed the request. Microsoft documents
    // that a whole-request routing decision can leave partialSuccess.rejectedSpans
    // at 0 while results shows every span rejected, so the per-sink statuses in
    // results are the only reliable proof that telemetry was actually accepted.
    private async Task EnsureExportAcceptedAsync(
        HttpResponseMessage response,
        Guid agentRegistrationId,
        string operation,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);

            EnsureNoPartialSuccessRejection(document.RootElement);
            EnsureEverySpanReachedASink(document.RootElement, agentRegistrationId, operation);
        }
        catch (Agent365ObservabilityExportException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new Agent365ObservabilityTransientException("InvalidExportResponse", exception);
        }
    }

    private static void EnsureNoPartialSuccessRejection(JsonElement root)
    {
        if (!root.TryGetProperty("partialSuccess", out var partialSuccess)
            || partialSuccess.ValueKind == JsonValueKind.Null)
        {
            return;
        }

        if (partialSuccess.ValueKind != JsonValueKind.Object)
            throw new Agent365ObservabilityConfigurationException("InvalidExportResponse");

        if (partialSuccess.TryGetProperty("rejectedSpans", out var rejectedSpans)
            && TryReadPositiveInt64(rejectedSpans))
        {
            throw new Agent365ObservabilityConfigurationException("SpansRejected");
        }
    }

    private void EnsureEverySpanReachedASink(
        JsonElement root,
        Guid agentRegistrationId,
        string operation)
    {
        if (!root.TryGetProperty("results", out var results)
            || results.ValueKind == JsonValueKind.Null)
        {
            // Responses that omit results leave partialSuccess as the only signal.
            return;
        }

        if (results.ValueKind != JsonValueKind.Array)
            throw new Agent365ObservabilityConfigurationException("InvalidExportResponse");

        var unroutedSinks = new List<string>();

        foreach (var result in results.EnumerateArray())
        {
            var sentSinks = 0;
            string? firstUnroutedReason = null;

            if (result.ValueKind == JsonValueKind.Object
                && result.TryGetProperty("sinks", out var sinks)
                && sinks.ValueKind == JsonValueKind.Object)
            {
                foreach (var sink in sinks.EnumerateObject())
                {
                    switch (ReadSinkStatus(sink))
                    {
                        case "sent":
                            sentSinks++;
                            break;
                        case "rejected":
                            throw new Agent365ObservabilityConfigurationException(
                                $"SpansRejected:{ReadSinkReason(sink)}");
                        default:
                            // not_routed, or a status this build does not recognize.
                            firstUnroutedReason ??= ReadSinkReason(sink);
                            unroutedSinks.Add(sink.Name);
                            break;
                    }
                }
            }

            if (sentSinks == 0)
            {
                throw new Agent365ObservabilityConfigurationException(
                    $"SpansNotRouted:{firstUnroutedReason ?? UnspecifiedReason}");
            }
        }

        if (unroutedSinks.Count > 0)
        {
            _logger.LogWarning(
                "Agent 365 accepted the {Operation} span for agent {AgentRegistrationId} but did not route it to sink(s) {UnroutedSinks}",
                operation,
                agentRegistrationId,
                string.Join(",", unroutedSinks.Distinct(StringComparer.Ordinal)));
        }
    }

    private static string? ReadSinkStatus(JsonProperty sink)
    {
        return sink.Value.ValueKind == JsonValueKind.Object
            && sink.Value.TryGetProperty("status", out var status)
            && status.ValueKind == JsonValueKind.String
                ? status.GetString()
                : null;
    }

    private static string ReadSinkReason(JsonProperty sink)
    {
        var reason = sink.Value.ValueKind == JsonValueKind.Object
            && sink.Value.TryGetProperty("reason", out var element)
            && element.ValueKind == JsonValueKind.String
                ? element.GetString()
                : null;

        return SanitizeSinkReason(reason);
    }

    // Sink reasons are a service-controlled enum such as tenant_not_licensed
    // rather than customer content, so they are safe to surface. Bound them
    // anyway: this value reaches persisted error codes and audit rows.
    private static string SanitizeSinkReason(string? reason)
    {
        if (string.IsNullOrWhiteSpace(reason))
            return UnspecifiedReason;

        var builder = new StringBuilder(MaxSinkReasonLength);
        foreach (var character in reason.Trim())
        {
            if (builder.Length == MaxSinkReasonLength)
                break;

            builder.Append(
                char.IsAsciiLetterOrDigit(character) || character is '_' or '-' or '.'
                    ? character
                    : '_');
        }

        return builder.Length == 0 ? UnspecifiedReason : builder.ToString();
    }

    private static bool TryReadPositiveInt64(JsonElement element)
    {
        return element.ValueKind switch
        {
            JsonValueKind.Number => element.TryGetInt64(out var value) && value > 0,
            JsonValueKind.String => long.TryParse(
                element.GetString(),
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out var value) && value > 0,
            _ => false
        };
    }

    private static async Task DelayForRetryAfterAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var retryAfter = response.Headers.RetryAfter?.Delta;
        if (retryAfter is null && response.Headers.RetryAfter?.Date is { } date)
            retryAfter = date - DateTimeOffset.UtcNow;

        if (retryAfter is null || retryAfter <= TimeSpan.Zero)
            return;

        await Task.Delay(
            retryAfter > TimeSpan.FromSeconds(30) ? TimeSpan.FromSeconds(30) : retryAfter.Value,
            cancellationToken);
    }

    private static bool IsTransient(HttpStatusCode statusCode)
    {
        var value = (int)statusCode;
        return value is 401 or 403 or 408 or 429 || value >= 500;
    }

    private static Guid ParseRequiredGuid(string? value, string errorCode)
    {
        if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
            throw new Agent365ObservabilityConfigurationException(errorCode);

        return parsed;
    }

    private static string NormalizeOperation(string value)
    {
        var operation = value.Trim().ToLowerInvariant();
        if (!SupportedOperations.Contains(operation))
            throw new Agent365ObservabilityConfigurationException("UnsupportedOperation");

        return operation;
    }

    private static string SanitizeRequired(string? value, string errorCode, int maximumLength)
    {
        return SanitizeOptional(value, maximumLength)
            ?? throw new Agent365ObservabilityConfigurationException(errorCode);
    }

    private static string? SanitizeOptional(string? value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;

        var builder = new StringBuilder(Math.Min(value.Length, maximumLength));
        foreach (var character in value.Trim())
        {
            if (builder.Length == maximumLength)
                break;

            builder.Append(char.IsControl(character) ? ' ' : character);
        }

        var sanitized = builder.ToString().Trim();
        return sanitized.Length == 0 ? null : sanitized;
    }

    private static string? SanitizeOpaqueIdentifier(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;

        var sanitized = SanitizeOptional(value, 512)!;
        if (Guid.TryParse(sanitized, out var guid) && guid != Guid.Empty)
            return guid.ToString("D");

        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sanitized)))
            .ToLowerInvariant();
    }

    private static string CreateHexId(string input, int byteCount)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        return Convert.ToHexString(hash.AsSpan(0, byteCount)).ToLowerInvariant();
    }

    private static DateTime NormalizeUtc(DateTime value)
    {
        return value.Kind switch
        {
            DateTimeKind.Utc => value,
            DateTimeKind.Local => value.ToUniversalTime(),
            _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
        };
    }

    private static string ToUnixNanoseconds(DateTime value)
    {
        var ticksSinceEpoch = value.Ticks - DateTime.UnixEpoch.Ticks;
        return checked(ticksSinceEpoch * 100L).ToString(CultureInfo.InvariantCulture);
    }

    private sealed record OtlpSpanPayload(
        string TraceId,
        string SpanId,
        string ParentSpanId,
        string Name,
        int Kind,
        string StartTimeUnixNano,
        string EndTimeUnixNano,
        OtlpStatusPayload Status,
        object[] Attributes);

    private sealed record OtlpStatusPayload(int Code);
}
