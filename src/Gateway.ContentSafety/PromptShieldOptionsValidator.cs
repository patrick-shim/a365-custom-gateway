using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

internal sealed class PromptShieldOptionsValidator : IValidateOptions<PromptShieldOptions>
{
    public ValidateOptionsResult Validate(string? name, PromptShieldOptions options)
    {
        if (options.RequestTimeoutSeconds is < 1 or > 30)
            return ValidateOptionsResult.Fail("PromptShield:RequestTimeoutSeconds must be between 1 and 30.");
        if (options.ReceiptLifetimeSeconds is < 30 or > 900)
            return ValidateOptionsResult.Fail("PromptShield:ReceiptLifetimeSeconds must be between 30 and 900.");
        if (!string.Equals(options.ApiVersion, "2024-09-01", StringComparison.Ordinal))
            return ValidateOptionsResult.Fail("PromptShield:ApiVersion must be the validated 2024-09-01 API version.");
        if (!options.Enabled)
            return ValidateOptionsResult.Success;
        if (!Uri.TryCreate(options.Endpoint, UriKind.Absolute, out var endpoint)
            || endpoint.Scheme != Uri.UriSchemeHttps
            || !string.IsNullOrEmpty(endpoint.Query)
            || !string.IsNullOrEmpty(endpoint.Fragment))
        {
            return ValidateOptionsResult.Fail("PromptShield:Endpoint must be a plain HTTPS Azure AI Content Safety endpoint.");
        }

        return ValidateOptionsResult.Success;
    }
}
