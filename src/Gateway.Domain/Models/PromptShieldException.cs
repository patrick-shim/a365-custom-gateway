namespace Gateway.Domain.Models;

public sealed class PromptShieldException : Exception
{
    public PromptShieldException(string failureCode, string message, bool isTransient = false)
        : base(message)
    {
        FailureCode = failureCode;
        IsTransient = isTransient;
    }

    public string FailureCode { get; }
    public bool IsTransient { get; }
}
