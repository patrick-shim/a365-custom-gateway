namespace Gateway.Application.Exceptions;

public sealed class ConflictException : Exception
{
    public string? ErrorCode { get; }
    public Guid? ConflictingOperationId { get; }

    public ConflictException(
        string message,
        string? errorCode = null,
        Exception? innerException = null,
        Guid? conflictingOperationId = null)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
        ConflictingOperationId = conflictingOperationId;
    }
}
