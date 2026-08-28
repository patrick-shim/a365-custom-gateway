using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Gateway.Domain.Models;

namespace Gateway.Purview;

internal sealed record PurviewGraphResponse(
    JsonObject Body,
    string? ETag,
    HttpStatusCode StatusCode);

internal interface IPurviewGraphClient
{
    Task<PurviewGraphResponse> PostAsync(
        string operation,
        string relativePath,
        JsonObject body,
        string? ifNoneMatch,
        CancellationToken cancellationToken);
}

internal sealed class PurviewGraphClient : IPurviewGraphClient
{
    internal static readonly Uri OfficialBaseAddress = new("https://graph.microsoft.com/v1.0/");

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IPurviewTokenProvider _tokenProvider;

    public PurviewGraphClient(
        IHttpClientFactory httpClientFactory,
        IPurviewTokenProvider tokenProvider)
    {
        _httpClientFactory = httpClientFactory;
        _tokenProvider = tokenProvider;
    }

    public async Task<PurviewGraphResponse> PostAsync(
        string operation,
        string relativePath,
        JsonObject body,
        string? ifNoneMatch,
        CancellationToken cancellationToken)
    {
        var token = await _tokenProvider.GetTokenAsync(cancellationToken);
        using var request = new HttpRequestMessage(HttpMethod.Post, relativePath)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json")
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        request.Headers.TryAddWithoutValidation("Client-Request-Id", Guid.NewGuid().ToString("D"));
        if (!string.IsNullOrWhiteSpace(ifNoneMatch))
            request.Headers.TryAddWithoutValidation("If-None-Match", ifNoneMatch);

        HttpResponseMessage response;
        try
        {
            response = await _httpClientFactory
                .CreateClient(nameof(PurviewGraphClient))
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (TaskCanceledException exception)
        {
            throw Failure(
                "PURVIEW_GRAPH_TIMEOUT",
                $"Microsoft Graph timed out during {operation}.",
                isTransient: true,
                exception);
        }
        catch (HttpRequestException exception)
        {
            throw Failure(
                "PURVIEW_GRAPH_NETWORK_FAILURE",
                $"Microsoft Graph could not be reached during {operation}.",
                isTransient: true,
                exception);
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var status = (int)response.StatusCode;
                var graphErrorCode = await ReadGraphErrorCodeAsync(response, cancellationToken);
                throw Failure(
                    graphErrorCode is null
                        ? $"PURVIEW_GRAPH_HTTP_{status}"
                        : $"PURVIEW_GRAPH_HTTP_{status}_{graphErrorCode}",
                    $"Microsoft Graph rejected Purview operation {operation} with HTTP {status}.",
                    IsTransient(response.StatusCode));
            }

            JsonObject responseBody;
            try
            {
                var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
                responseBody = string.IsNullOrWhiteSpace(responseText)
                    ? new JsonObject()
                    : JsonNode.Parse(responseText) as JsonObject
                      ?? throw Failure(
                        "PURVIEW_GRAPH_INVALID_RESPONSE",
                        $"Microsoft Graph returned an invalid response during {operation}.");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (PurviewPolicyException)
            {
                throw;
            }
            catch (JsonException exception)
            {
                throw Failure(
                    "PURVIEW_GRAPH_INVALID_RESPONSE",
                    $"Microsoft Graph returned an invalid response during {operation}.",
                    innerException: exception);
            }

            return new PurviewGraphResponse(
                responseBody,
                response.Headers.ETag?.ToString(),
                response.StatusCode);
        }
    }

    private static bool IsTransient(HttpStatusCode statusCode)
    {
        var value = (int)statusCode;
        return value is 408 or 429 || value >= 500;
    }

    private static async Task<string?> ReadGraphErrorCodeAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        try
        {
            var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
            var rawCode = (JsonNode.Parse(responseText) as JsonObject)?["error"]?["code"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(rawCode))
                return null;

            var safeCode = new string(rawCode
                .Where(static character => char.IsAsciiLetterOrDigit(character) || character == '_')
                .Take(64)
                .ToArray());
            return string.IsNullOrWhiteSpace(safeCode)
                ? null
                : safeCode.ToUpperInvariant();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception) when (response.Content is not null)
        {
            return null;
        }
    }

    private static PurviewPolicyException Failure(
        string code,
        string message,
        bool isTransient = false,
        Exception? innerException = null) =>
        new(code, message, isTransient, innerException);
}
