using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

public sealed class PromptShieldClient : IPromptShieldClient
{
    private readonly HttpClient _httpClient;
    private readonly IPromptShieldTokenProvider _tokenProvider;
    private readonly PromptShieldOptions _options;

    internal PromptShieldClient(
        HttpClient httpClient,
        IPromptShieldTokenProvider tokenProvider,
        IOptions<PromptShieldOptions> options)
    {
        _httpClient = httpClient;
        _tokenProvider = tokenProvider;
        _options = options.Value;
    }

    public bool IsEnabled => _options.Enabled;
    public TimeSpan ReceiptLifetime => TimeSpan.FromSeconds(_options.ReceiptLifetimeSeconds);

    public async Task<PromptShieldEvaluationResult> EvaluateAsync(
        string prompt,
        PromptShieldSubject subject,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(subject);
        if (!IsEnabled)
            throw new PromptShieldException("PROMPT_SHIELD_NOT_CONFIGURED", "Prompt Shields is not enabled.");

        // Attribute the outbound evaluation to the calling agent on the ambient span,
        // so a verdict in the trace can be traced back to one Agent 365 identity.
        // The identity is deliberately not added to the request body: Prompt Shields
        // has no field for it, and inventing one would ship tenant identifiers to the
        // provider for no decision benefit.
        var activity = Activity.Current;
        if (activity is not null)
        {
            activity.SetTag("gateway.agent.registration_id", subject.AgentRegistrationId.ToString("D"));
            activity.SetTag("gateway.correlation.id", subject.CorrelationId);
            activity.SetTag(
                "gateway.a365.agent_id",
                subject.Agent365AgentId?.ToString("D") ?? "unknown");
            activity.SetTag(
                "gateway.a365.blueprint_id",
                subject.BlueprintId?.ToString("D") ?? "unknown");
        }

        try
        {
            var token = await _tokenProvider.GetTokenAsync(cancellationToken);
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"contentsafety/text:shieldPrompt?api-version={Uri.EscapeDataString(_options.ApiVersion)}")
            {
                Content = JsonContent.Create(new { userPrompt = prompt })
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

            using var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new PromptShieldException("PROMPT_SHIELD_FORBIDDEN", "Azure AI Content Safety rejected the Gateway identity.");
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
                throw new PromptShieldException("PROMPT_SHIELD_THROTTLED", "Azure AI Content Safety throttled the evaluation.", true);
            if (response.StatusCode != HttpStatusCode.OK)
                throw new PromptShieldException("PROMPT_SHIELD_INVALID_STATUS", "Azure AI Content Safety did not return a trusted decision.", true);

            try
            {
                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
                using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
                if (!document.RootElement.TryGetProperty("userPromptAnalysis", out var analysis)
                    || !analysis.TryGetProperty("attackDetected", out var attackDetected)
                    || attackDetected.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
                {
                    throw new PromptShieldException("PROMPT_SHIELD_INVALID_RESPONSE", "Azure AI Content Safety returned an invalid decision.");
                }

                return new PromptShieldEvaluationResult(attackDetected.GetBoolean());
            }
            catch (JsonException)
            {
                throw new PromptShieldException("PROMPT_SHIELD_INVALID_RESPONSE", "Azure AI Content Safety returned invalid JSON.");
            }
        }
        catch (PromptShieldException)
        {
            throw;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new PromptShieldException("PROMPT_SHIELD_TIMEOUT", "Azure AI Content Safety timed out.", true);
        }
        catch (Exception exception) when (
            exception is HttpRequestException
            or Azure.Identity.AuthenticationFailedException
            or Azure.Identity.CredentialUnavailableException
            or IOException)
        {
            throw new PromptShieldException("PROMPT_SHIELD_UNAVAILABLE", "Azure AI Content Safety could not return a trusted decision.", true);
        }
    }
}
