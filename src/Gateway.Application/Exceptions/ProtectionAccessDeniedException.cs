namespace Gateway.Application.Exceptions;

public sealed class ProtectionAccessDeniedException : Exception
{
    public ProtectionAccessDeniedException()
        : base("The protection operation is not authorized for this delegated user and tenant.")
    {
    }
}
