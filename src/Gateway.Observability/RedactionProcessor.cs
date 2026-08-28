using System.Diagnostics;
using OpenTelemetry;

namespace Gateway.Observability;

public sealed class RedactionProcessor : BaseProcessor<Activity>
{
    private static readonly string[] SensitiveAttributeFragments =
    {
        "access_token",
        "authorization",
        "secret",
        "password",
        "api_key",
        "apikey",
        "prompt",
        "response.content",
        "content_blob",
        "contentblob",
        "content.uri"
    };

    private const string RedactedValue = "[REDACTED]";

    public override void OnEnd(Activity data)
    {
        foreach (var tag in data.TagObjects)
        {
            if (SensitiveAttributeFragments.Any(fragment =>
                tag.Key.Contains(fragment, StringComparison.OrdinalIgnoreCase)))
            {
                data.SetTag(tag.Key, RedactedValue);
            }
        }
    }
}
