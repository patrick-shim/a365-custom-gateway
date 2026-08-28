namespace Gateway.Domain.Models;

/// <summary>
/// A safe, content-free failure raised when a Purview policy decision cannot be
/// obtained or trusted. Callers must fail closed and must not expose the inner
/// exception or Microsoft Graph response body.
/// </summary>
public sealed class PurviewPolicyException : Exception
{
    public string FailureCode { get; }
    public bool IsTransient { get; }

    public PurviewPolicyException(
        string failureCode,
        string message,
        bool isTransient = false,
        Exception? innerException = null)
        : base(message, innerException)
    {
        FailureCode = failureCode;
        IsTransient = isTransient;
    }
}
