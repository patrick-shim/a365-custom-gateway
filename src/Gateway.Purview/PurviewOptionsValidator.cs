using Gateway.Domain.Enums;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

internal sealed class PurviewOptionsValidator : IValidateOptions<PurviewOptions>
{
    public ValidateOptionsResult Validate(string? name, PurviewOptions options)
    {
        if (options.ProtectionScopeCacheMinutes is < 1 or > 1440)
            return ValidateOptionsResult.Fail(
                "Purview:ProtectionScopeCacheMinutes must be between 1 and 1440.");

        if (options.RequestTimeoutSeconds is < 1 or > 120)
            return ValidateOptionsResult.Fail(
                "Purview:RequestTimeoutSeconds must be between 1 and 120.");

        if (!Enum.TryParse<PurviewMode>(options.DefaultMode, ignoreCase: false, out _))
            return ValidateOptionsResult.Fail(
                "Purview:DefaultMode must be AuditOnly or Enforce.");

        if (string.IsNullOrWhiteSpace(options.AppName) || options.AppName.Length > 256)
            return ValidateOptionsResult.Fail(
                "Purview:AppName must be between 1 and 256 characters.");

        if (string.IsNullOrWhiteSpace(options.AppVersion) || options.AppVersion.Length > 64)
            return ValidateOptionsResult.Fail(
                "Purview:AppVersion must be between 1 and 64 characters.");

        if (!string.IsNullOrWhiteSpace(options.ManagedIdentityClientId)
            && (!Guid.TryParse(options.ManagedIdentityClientId, out var clientId)
                || clientId == Guid.Empty))
        {
            return ValidateOptionsResult.Fail(
                "Purview:ManagedIdentityClientId must be a non-empty GUID when configured.");
        }

        return ValidateOptionsResult.Success;
    }
}
