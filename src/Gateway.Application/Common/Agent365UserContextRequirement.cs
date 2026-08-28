using Gateway.Application.Exceptions;
using Gateway.Domain.Enums;

namespace Gateway.Application.Common;

internal static class Agent365UserContextRequirement
{
    internal const string RequiredErrorMessage =
        "A valid tenant user object ID is required when Agent 365 observability is enabled.";
    internal const string InvalidErrorMessage =
        "Tenant user object ID must be a valid, non-empty GUID.";

    public static bool IsSatisfied(ObservabilityMode mode, string? tenantUserObjectId)
    {
        var agent365Enabled = mode.ToDestinations().Agent365ObservabilityEnabled;

        if (tenantUserObjectId is null)
            return !agent365Enabled;

        return Guid.TryParse(tenantUserObjectId, out var objectId) && objectId != Guid.Empty;
    }

    public static void EnsureSatisfied(
        ObservabilityMode mode,
        string? tenantUserObjectId,
        string propertyName)
    {
        if (IsSatisfied(mode, tenantUserObjectId))
            return;

        throw new ValidationException(new Dictionary<string, string[]>
        {
            [propertyName] = [GetErrorMessage(tenantUserObjectId)]
        });
    }

    public static string GetErrorMessage(string? tenantUserObjectId) =>
        tenantUserObjectId is null ? RequiredErrorMessage : InvalidErrorMessage;
}
