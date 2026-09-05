namespace Gateway.Application.Exceptions;

public sealed class PreconditionFailedException : Exception
{
    public string ErrorCode { get; }

    public PreconditionFailedException(string message, string errorCode)
        : base(message)
    {
        ErrorCode = errorCode;
    }
}
