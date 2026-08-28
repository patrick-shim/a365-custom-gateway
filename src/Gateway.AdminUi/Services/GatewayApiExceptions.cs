using System.Net;

namespace Gateway.AdminUi.Services;

public abstract class GatewayApiClientException : Exception
{
    protected GatewayApiClientException(
        string message,
        string? correlationId = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        CorrelationId = correlationId;
    }

    public string? CorrelationId { get; }
}

public sealed class GatewayApiException : GatewayApiClientException
{
    public GatewayApiException(
        HttpStatusCode statusCode,
        string title,
        string? detail,
        string? type,
        string? instance,
        string? errorCode,
        string? correlationId,
        IReadOnlyDictionary<string, string[]> validationErrors,
        TimeSpan? retryAfter,
        bool requiresUserInteraction = false,
        bool hasClaimsChallenge = false,
        IReadOnlyList<string>? requiredScopes = null)
        : base(string.IsNullOrWhiteSpace(detail) ? title : $"{title} {detail}", correlationId)
    {
        StatusCode = statusCode;
        Title = title;
        Detail = detail;
        Type = type;
        Instance = instance;
        ErrorCode = errorCode;
        ValidationErrors = validationErrors;
        RetryAfter = retryAfter;
        RequiresUserInteraction = requiresUserInteraction;
        HasClaimsChallenge = hasClaimsChallenge;
        RequiredScopes = requiredScopes ?? [];
    }

    public HttpStatusCode StatusCode { get; }

    public string Title { get; }

    public string? Detail { get; }

    public string? Type { get; }

    public string? Instance { get; }

    public string? ErrorCode { get; }

    public IReadOnlyDictionary<string, string[]> ValidationErrors { get; }

    public TimeSpan? RetryAfter { get; }

    public bool RequiresUserInteraction { get; }

    public bool HasClaimsChallenge { get; }

    public IReadOnlyList<string> RequiredScopes { get; }

    public bool IsTransient =>
        StatusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests ||
        (int)StatusCode >= 500;
}

public sealed class GatewayAuthenticationRequiredException : GatewayApiClientException
{
    public GatewayAuthenticationRequiredException(Exception? innerException = null)
        : base("Your session cannot authorize this request. Sign in again to continue.", innerException: innerException)
    {
    }
}

public sealed class GatewayApiTransportException : GatewayApiClientException
{
    public GatewayApiTransportException(
        string message,
        string correlationId,
        Exception innerException)
        : base(message, correlationId, innerException)
    {
    }
}

public sealed class GatewayApiProtocolException : GatewayApiClientException
{
    public GatewayApiProtocolException(
        string message,
        string? correlationId,
        Exception? innerException = null)
        : base(message, correlationId, innerException)
    {
    }
}
