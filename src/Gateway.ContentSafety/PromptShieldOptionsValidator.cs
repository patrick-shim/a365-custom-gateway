using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

internal sealed class PromptShieldOptionsValidator : IValidateOptions<PromptShieldOptions>
{
    private readonly BootstrapPromptShieldRuntimeBinding _runtimeBinding;

    public PromptShieldOptionsValidator(
        BootstrapPromptShieldRuntimeBinding runtimeBinding)
    {
        _runtimeBinding = runtimeBinding;
    }

    public ValidateOptionsResult Validate(string? name, PromptShieldOptions options)
    {
        if (options.RequestTimeoutSeconds is < 1 or > 30)
            return ValidateOptionsResult.Fail("PromptShield:RequestTimeoutSeconds must be between 1 and 30.");
        if (options.ReceiptLifetimeSeconds is < 30 or > 900)
            return ValidateOptionsResult.Fail("PromptShield:ReceiptLifetimeSeconds must be between 30 and 900.");
        if (!string.Equals(options.ApiVersion, "2024-09-01", StringComparison.Ordinal))
            return ValidateOptionsResult.Fail("PromptShield:ApiVersion must be the validated 2024-09-01 API version.");
        if (!string.IsNullOrWhiteSpace(options.ManagedIdentityClientId) &&
            (!Guid.TryParse(options.ManagedIdentityClientId, out var clientId) || clientId == Guid.Empty))
        {
            return ValidateOptionsResult.Fail(
                "PromptShield:ManagedIdentityClientId must be a non-empty GUID.");
        }
        if (!options.Enabled)
            return ValidateOptionsResult.Success;
        if (!Uri.TryCreate(options.Endpoint, UriKind.Absolute, out var endpoint)
            || endpoint.Scheme != Uri.UriSchemeHttps
            || !string.IsNullOrEmpty(endpoint.Query)
            || !string.IsNullOrEmpty(endpoint.Fragment))
        {
            return ValidateOptionsResult.Fail("PromptShield:Endpoint must be a plain HTTPS Azure AI Content Safety endpoint.");
        }

        if (options.UsesApiKey)
        {
            if (string.IsNullOrWhiteSpace(options.ApiKey))
                return ValidateOptionsResult.Fail("PromptShield:ApiKey is required when AuthMode is ApiKey.");
            if (!string.IsNullOrWhiteSpace(options.ManagedIdentityClientId))
                return ValidateOptionsResult.Fail("PromptShield:ManagedIdentityClientId must be empty when AuthMode is ApiKey.");
            return ValidateOptionsResult.Success;
        }

        if (options.UsesClientSecret)
        {
            if (string.IsNullOrWhiteSpace(options.TenantId) ||
                !Guid.TryParse(options.TenantId, out var tenantId) ||
                tenantId == Guid.Empty)
            {
                return ValidateOptionsResult.Fail("PromptShield:TenantId must be a non-empty GUID when AuthMode is ClientSecret.");
            }

            if (string.IsNullOrWhiteSpace(options.ClientId) ||
                !Guid.TryParse(options.ClientId, out var appClientId) ||
                appClientId == Guid.Empty)
            {
                return ValidateOptionsResult.Fail("PromptShield:ClientId must be a non-empty GUID when AuthMode is ClientSecret.");
            }

            if (string.IsNullOrWhiteSpace(options.ClientSecret))
                return ValidateOptionsResult.Fail("PromptShield:ClientSecret is required when AuthMode is ClientSecret.");

            if (!string.IsNullOrWhiteSpace(options.ManagedIdentityClientId))
                return ValidateOptionsResult.Fail("PromptShield:ManagedIdentityClientId must be empty when AuthMode is ClientSecret.");

            return ValidateOptionsResult.Success;
        }

        if (!string.Equals(options.AuthMode, PromptShieldOptions.AuthModeManagedIdentity, StringComparison.OrdinalIgnoreCase))
            return ValidateOptionsResult.Fail("PromptShield:AuthMode must be ManagedIdentity, ApiKey, or ClientSecret.");

        if (!_runtimeBinding.IsConfigurationExact(options))
        {
            return ValidateOptionsResult.Fail(
                "Prompt Shields capability binding is unavailable.");
        }

        return ValidateOptionsResult.Success;
    }
}
