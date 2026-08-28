using Gateway.AdminUi.Services;

namespace Gateway.AdminUi.Components.Shared;

public sealed record UiErrorInfo(
    string Message,
    string? CorrelationId = null,
    bool RequiresUserInteraction = false,
    bool HasClaimsChallenge = false,
    IReadOnlyList<string>? RequiredScopes = null)
{
    public static UiErrorInfo FromException(Exception exception) => exception switch
    {
        GatewayApiException { RequiresUserInteraction: true } apiException => new(
            apiException.HasClaimsChallenge
                ? "Conditional Access requires another Microsoft Entra sign-in step. Sign in again and complete the requested interaction before retrying."
                : "Additional Microsoft Graph consent is required. Sign in again; if no prompt appears, ask an Entra administrator to grant the required delegated permissions.",
            apiException.CorrelationId,
            RequiresUserInteraction: true,
            apiException.HasClaimsChallenge,
            apiException.RequiredScopes),
        GatewayApiException apiException => new(apiException.Detail ?? apiException.Title, apiException.CorrelationId),
        GatewayApiClientException clientException => new(clientException.Message, clientException.CorrelationId),
        OperationCanceledException => new("The request was cancelled."),
        _ => new("The gateway could not complete the request. Try again or contact support if the problem continues.")
    };
}
