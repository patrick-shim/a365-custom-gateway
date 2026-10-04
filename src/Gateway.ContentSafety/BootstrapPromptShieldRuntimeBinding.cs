using Gateway.Application.Protection;

namespace Gateway.ContentSafety;

internal sealed class BootstrapPromptShieldRuntimeBinding(Func<PromptShieldOptions> runtimeOptions)
    : IBootstrapPromptShieldRuntimeBinding
{
    public bool IsRuntimeReady()
    {
        var runtime = runtimeOptions();
        if (!runtime.Enabled ||
            !Uri.TryCreate(runtime.Endpoint, UriKind.Absolute, out var endpoint) ||
            endpoint.Scheme != Uri.UriSchemeHttps)
        {
            return false;
        }

        if (runtime.UsesApiKey)
            return !string.IsNullOrWhiteSpace(runtime.ApiKey);

        if (runtime.UsesClientSecret)
        {
            return !string.IsNullOrWhiteSpace(runtime.TenantId) &&
                !string.IsNullOrWhiteSpace(runtime.ClientId) &&
                !string.IsNullOrWhiteSpace(runtime.ClientSecret);
        }

        return false;
    }

}
