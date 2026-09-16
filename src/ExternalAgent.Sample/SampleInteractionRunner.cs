using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace ExternalAgent.Sample;

internal static class SampleInteractionRunner
{
    internal static async Task<int> RunAsync(
        HttpClient client,
        Arguments options,
        Func<string, CancellationToken, Task<string>> generateResponse,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default,
        TimeProvider? timeProvider = null)
    {
        var clock = timeProvider ?? TimeProvider.System;
        var generationStarted = false;
        try
        {
            var suffix = Guid.NewGuid().ToString("N");
            var occurredAtUtc = clock.GetUtcNow();
            var sessionId = $"sample-session-{suffix}";
            var interactionId = $"sample-interaction-{suffix}";
            var prompt = new { contentType = "text/plain", content = options.Message };
            var userContext = new { tenantUserObjectId = options.TenantUserObjectId };

            // Always ask the Gateway: local feature guesses become stale after an operator edit.
            using var evaluationResponse = await PostAsync(client, "api/v1/prompts:evaluate",
                new { externalAgentId = options.ExternalAgentId, interactionId, occurredAtUtc, userContext, prompt },
                cancellationToken);
            if (evaluationResponse.StatusCode == HttpStatusCode.Forbidden)
            {
                error.WriteLine("[BLOCKED] The Gateway rejected prompt evaluation (HTTP 403). No model call was made.");
                return 3;
            }
            if (evaluationResponse.StatusCode != HttpStatusCode.OK)
            {
                error.WriteLine($"[FAILED] Prompt evaluation returned HTTP {(int)evaluationResponse.StatusCode}. No model call was made.");
                return 4;
            }
            var evaluation = await evaluationResponse.Content.ReadFromJsonAsync<PromptEvaluation>(
                cancellationToken: cancellationToken);
            if (evaluation is not { Allowed: true, EvaluationReceiptId: { } receiptId } || receiptId == Guid.Empty)
            {
                error.WriteLine("[FAILED] Prompt evaluation did not return an allowed decision with a valid receipt. No model call was made.");
                return 4;
            }
            if (!TryReadDeadline(evaluation.ExpiresAtUtc, out var expiresAtUtc) || expiresAtUtc <= clock.GetUtcNow())
            {
                error.WriteLine("[FAILED] Prompt evaluation returned a missing, malformed, or expired receipt deadline. No model call was made.");
                return 4;
            }

            output.WriteLine(
                $"[ALLOWED] Gateway permitted this prompt; Prompt Shields={SafePromptShieldStatus(evaluation.PromptShieldProcessing)}; " +
                $"Purview={SafePurviewStatus(evaluation.PurviewProcessing)}; correlation {SafeCorrelationId(evaluation.CorrelationId)}");
            if (evaluation.PurviewProcessing == "SimulationUnavailable")
                error.WriteLine("[WARNING] Purview simulation is unavailable, not disabled or proven protective. The Gateway allowed this non-enforcing interaction.");

            if (!await IngestAsync(client, "api/v1/agent-activities",
                    new
                    {
                        externalAgentId = options.ExternalAgentId,
                        activityId = $"sample-activity-{suffix}",
                        sessionId,
                        activityType = "Chat",
                        occurredAtUtc,
                        actor = new { type = "User", tenantUserObjectId = options.TenantUserObjectId },
                        tool = (object?)null,
                        attributes = new Dictionary<string, string> { ["sample"] = "external-agent", ["transport"] = "gateway" }
                    },
                    "activity/OTel ingestion", output, error, cancellationToken))
                return 4;

            cancellationToken.ThrowIfCancellationRequested();
            if (expiresAtUtc <= clock.GetUtcNow())
            {
                error.WriteLine("[FAILED] The prompt evaluation receipt expired before generation. No model call was made; no automatic retry was attempted.");
                return 4;
            }
            generationStarted = true;
            var generatedResponse = await generateResponse(options.Message, cancellationToken);
            if (!await IngestAsync(client, "api/v1/ai-interactions",
                    new
                    {
                        externalAgentId = options.ExternalAgentId,
                        interactionId,
                        sessionId,
                        occurredAtUtc,
                        userContext,
                        prompt,
                        response = new { contentType = "text/plain", content = generatedResponse },
                        model = (object?)null,
                        metadata = new Dictionary<string, string> { ["sample"] = "external-agent", ["transport"] = "gateway" },
                        promptEvaluationReceiptId = receiptId
                    },
                    "message ingestion", output, error, cancellationToken))
            {
                error.WriteLine("[WARNING] Generation already completed. Do not repeat the model call or ingestion blindly.");
                return 4;
            }

            output.WriteLine("[PASS] The Gateway accepted the sample message and telemetry; downstream delivery is not yet proven.");
            return 0;
        }
        catch (Exception)
        {
            error.WriteLine("[FAILED] The sample could not complete. Dependency response bodies and exception details were not rendered.");
            error.WriteLine(generationStarted
                ? "[WARNING] Generation or ingestion may already have completed. Do not repeat either blindly."
                : "[FAILED] No model call was made. Any earlier ingestion may already have been accepted.");
            return 4;
        }
    }

    private static async Task<HttpResponseMessage> PostAsync(
        HttpClient client, string path, object body, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(body) };
        request.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString("D"));
        return await client.SendAsync(request, cancellationToken);
    }

    private static async Task<bool> IngestAsync(
        HttpClient client, string path, object body, string label,
        TextWriter output, TextWriter error, CancellationToken cancellationToken)
    {
        using var response = await PostAsync(client, path, body, cancellationToken);
        if (response.StatusCode != HttpStatusCode.Accepted)
        {
            error.WriteLine($"[FAILED] {label} returned HTTP {(int)response.StatusCode}; expected 202. The response body was not rendered.");
            return false;
        }

        var correlationId = response.Headers.TryGetValues("X-Correlation-ID", out var values)
            ? values.FirstOrDefault() : null;
        output.WriteLine($"[PASS] {label}: HTTP 202 correlation {SafeCorrelationId(correlationId)}");
        return true;
    }

    private static string SafeCorrelationId(string? value) =>
        Guid.TryParse(value, out var correlationId) && correlationId != Guid.Empty
            ? correlationId.ToString("D") : "unavailable";

    private static bool TryReadDeadline(JsonElement element, out DateTimeOffset deadline)
    {
        deadline = default;
        if (element.ValueKind != JsonValueKind.String || element.GetString() is not { } text)
            return false;
        // Do not interpret a timezone-free server deadline using the machine's local zone.
        var hasOffset = text.EndsWith('Z') ||
            (text.Length >= 6 && text[^3] == ':' && text[^6] is '+' or '-');
        return hasOffset && element.TryGetDateTimeOffset(out deadline);
    }

    private static string SafePromptShieldStatus(string? value) => value switch
    {
        "Allowed" or "Blocked" or "Disabled" => value,
        _ => "Unknown"
    };

    private static string SafePurviewStatus(string? value) => value switch
    {
        "Allowed" or "Blocked" or "AuditOnly" or "AuditLogged" or "PurviewSkipped_NoUserContext" or
        "PurviewSkipped_InvalidUser" or "PurviewDisabled" or "SimulationUnavailable" or "SimulatedBlock" => value,
        _ => "Unknown"
    };

    private sealed record PromptEvaluation(
        Guid? EvaluationReceiptId,
        bool Allowed,
        string? PromptShieldProcessing,
        string? PurviewProcessing,
        string? CorrelationId,
        JsonElement ExpiresAtUtc);
}
