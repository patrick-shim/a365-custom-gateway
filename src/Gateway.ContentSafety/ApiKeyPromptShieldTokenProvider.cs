using Azure.Core;
using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

/// <summary>
/// Runtime Content Safety auth: subscription key presented as a bearer stand-in
/// is not used — <see cref="PromptShieldClient"/> switches to the subscription-key
/// header when <see cref="PromptShieldOptions.AuthMode"/> is ApiKey. This type
/// satisfies DI and token-identity skip paths.
/// </summary>
internal sealed class ApiKeyPromptShieldTokenProvider : IPromptShieldTokenProvider
{
    private readonly string _apiKey;

    public ApiKeyPromptShieldTokenProvider(IOptions<PromptShieldOptions> options)
    {
        var key = options.Value.ApiKey;
        if (string.IsNullOrWhiteSpace(key))
            throw new InvalidOperationException("PromptShield:ApiKey is required when AuthMode is ApiKey.");
        _apiKey = key;
    }

    public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
    {
        // Never sent as Bearer; PromptShieldClient uses Ocp-Apim-Subscription-Key.
        return ValueTask.FromResult(new AccessToken(_apiKey, DateTimeOffset.UtcNow.AddHours(1)));
    }
}
