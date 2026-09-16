using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Options;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;

namespace Gateway.AdminUi.Services;

// Only the HTTP portal endpoint uses this client. It is deliberately absent from the
// circuit's IGatewayApiClient, so execution content never needs to pass through Blazor.
public interface IPurviewRuntimeExecutionClient
{
    Task<PurviewRuntimeTestResultResponse> ExecuteAsync(ClaimsPrincipal user, Guid profileId,
        RuntimePortalExecutionRequest request, CancellationToken cancellationToken);
}

public sealed class PurviewRuntimeExecutionClient(
    IHttpClientFactory clients,
    ITokenAcquisition tokens,
    IOptions<GatewayApiOptions> options) : IPurviewRuntimeExecutionClient
{
    public const string ClientName = "GatewayRuntimeExecution";

    public async Task<PurviewRuntimeTestResultResponse> ExecuteAsync(ClaimsPrincipal user, Guid profileId,
        RuntimePortalExecutionRequest request, CancellationToken cancellationToken)
    {
        if (user.Identity?.IsAuthenticated != true || !user.IsInRole(GatewayRoles.Administrator))
            throw new InvalidOperationException("Runtime execution requires an administrator.");
        using var client = clients.CreateClient(ClientName);
        if (client.BaseAddress?.Scheme != Uri.UriSchemeHttps ||
            client.Timeout != Timeout.InfiniteTimeSpan && client.Timeout < TimeSpan.FromSeconds(75))
            throw new InvalidOperationException("Runtime execution requires HTTPS and a dedicated long-timeout client.");
        using var confirmationDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        confirmationDeadline.CancelAfter(TimeSpan.FromSeconds(60));
        var accessToken = await tokens.GetAccessTokenForUserAsync(
            options.Value.Scopes, authenticationScheme: OpenIdConnectDefaults.AuthenticationScheme, user: user).WaitAsync(confirmationDeadline.Token);
        using var confirm = new HttpRequestMessage(HttpMethod.Post, "api/v1/protection/operation-reviews:confirm")
        {
            Content = JsonContent.Create(new ConfirmProtectionOperationReviewRequest(request.ReviewTokenId, request.ReviewToken))
        };
        confirm.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        using var confirmed = await client.SendAsync(confirm, HttpCompletionOption.ResponseHeadersRead, confirmationDeadline.Token);
        if (!confirmed.IsSuccessStatusCode)
            throw new InvalidOperationException("Runtime confirmation failed; obtain a fresh review.");
        var confirmation = await confirmed.Content.ReadFromJsonAsync<ProtectionOperationConfirmationResponse>(confirmationDeadline.Token);
        if (confirmation is null || confirmation.ReviewTokenId != request.ReviewTokenId ||
            confirmation.ConfirmationTokenId != request.ReviewTokenId || confirmation.ExpiresAtUtc <= DateTime.UtcNow ||
            string.IsNullOrWhiteSpace(confirmation.ConfirmationToken))
            throw new InvalidOperationException("Runtime confirmation was not valid for this review.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(120));
        using var message = new HttpRequestMessage(HttpMethod.Post,
            $"api/v1/protection/purview/dlp-profiles/{profileId:D}:test-runtime")
        {
            Content = JsonContent.Create(new ExecutePurviewDlpRuntimeTestRequest(confirmation.ConfirmationTokenId,
                confirmation.ConfirmationToken, request.IdempotencyKey, request.ExpectedRowVersion, request.Samples))
        };
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        message.Headers.TryAddWithoutValidation("If-Match", request.ExpectedRowVersion);
        message.Headers.TryAddWithoutValidation("Idempotency-Key", request.IdempotencyKey.ToString("D"));
        message.Headers.TryAddWithoutValidation("X-Correlation-ID", Guid.NewGuid().ToString("D"));
        // One execution POST only; confirmation above contains metadata, never samples.
        // Neither request nor error bodies are logged or placed in replay state.
        using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException("The runtime execution was not completed. Recover its safe report.");
        var result = await response.Content.ReadFromJsonAsync<PurviewRuntimeTestResultResponse>(deadline.Token);
        if (result is null || !RuntimeTestUiProtocol.IsSafeReport(result, request.ReviewTokenId))
            throw new InvalidOperationException("The runtime execution report was not recognized.");
        return result;
    }
}
