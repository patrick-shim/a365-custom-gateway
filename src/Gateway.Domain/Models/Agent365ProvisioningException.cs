namespace Gateway.Domain.Models;

/// <summary>
/// A provisioning failure whose code and summary are safe to persist and display.
/// Dependency response bodies and credentials must never be used as the summary.
/// </summary>
public sealed class Agent365ProvisioningException : Exception
{
    public Agent365ProvisioningException(
        string errorCode,
        string safeSummary,
        bool isTransient = false,
        bool requiresManualIntervention = false)
        : base(safeSummary)
    {
        ErrorCode = errorCode;
        SafeSummary = safeSummary;
        IsTransient = isTransient;
        RequiresManualIntervention = requiresManualIntervention;
    }

    public string ErrorCode { get; }
    public string SafeSummary { get; }
    public bool IsTransient { get; }
    public bool RequiresManualIntervention { get; }
}
