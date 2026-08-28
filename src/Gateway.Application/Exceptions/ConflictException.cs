namespace Gateway.Application.Exceptions;

public sealed class ConflictException : Exception
{
    public string? ErrorCode { get; }

    public ConflictException(
        string message,
        string? errorCode = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }
}
