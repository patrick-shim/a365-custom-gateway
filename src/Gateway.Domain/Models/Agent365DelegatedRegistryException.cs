namespace Gateway.Domain.Models;

/// <summary>
/// A safe delegated Registry failure. Once <see cref="MutationMayHaveOccurred"/>
/// is true, the logical create must never be repeated.
/// </summary>
public sealed class Agent365DelegatedRegistryException : Exception
{
    public Agent365DelegatedRegistryException(
        string errorCode,
        string safeSummary,
        bool mutationMayHaveOccurred,
        bool isTransient = false,
        Exception? innerException = null)
        : base(safeSummary, innerException)
    {
        ErrorCode = errorCode;
        SafeSummary = safeSummary;
        MutationMayHaveOccurred = mutationMayHaveOccurred;
        IsTransient = isTransient;
    }

    public string ErrorCode { get; }
    public string SafeSummary { get; }
    public bool MutationMayHaveOccurred { get; }
    public bool IsTransient { get; }
}
