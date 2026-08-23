using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

public sealed class ObservabilityExporter : IObservabilityExporter
{
    private readonly ILogger<ObservabilityExporter> _logger;
    private readonly Agent365Options _options;
    private readonly IHttpClientFactory _httpClientFactory;

    public ObservabilityExporter(
        ILogger<ObservabilityExporter> logger,
        IOptions<Agent365Options> options,
        IHttpClientFactory httpClientFactory)
    {
        _logger = logger;
        _options = options.Value;
        _httpClientFactory = httpClientFactory;
    }

    public Task ExportActivityAsync(
        ObservabilityExportRequest request,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation(
            "Exporting activity span for agent {AgentRegistrationId}, spanType {SpanType}, correlationId {CorrelationId}",
            request.AgentRegistrationId,
            request.SpanType,
            request.CorrelationId);

        // OTLP endpoint: https://agent365.svc.cloud.microsoft
        // Auth: Agent365.Observability.OtelWrite permission
        //
        // Span type mapping to Agent 365 semantic conventions:
        //   "invoke_agent" -> Agent invocation span
        //   "execute_tool" -> Tool execution span
        //   "chat"         -> Chat interaction span
        //   "output_messages" -> Output message delivery span
        //
        // Export flow:
        // 1. Acquire token with Agent365.Observability.OtelWrite scope via managed identity
        // 2. Map the request attributes to OTLP ResourceSpans
        // 3. Set span name from request.SpanType
        // 4. Set start/end timestamps from request.StartedAtUtc / EndedAtUtc
        // 5. Set trace context from request.CorrelationId
        // 6. Add agent-specific attributes (agent365.agent.id, session.id, user.id)
        // 7. POST to OTLP endpoint with Bearer token
        // 8. Handle 401/403 by logging and returning without retry
        // 9. Handle transient errors with standard retry policy

        throw new NotImplementedException(
            "Requires OTLP export to https://agent365.svc.cloud.microsoft with Agent365.Observability.OtelWrite permission. "
            + "Span types: invoke_agent, execute_tool, chat, output_messages.");
    }
}
