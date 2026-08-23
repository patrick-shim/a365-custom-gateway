using System.Diagnostics;
using OpenTelemetry;

namespace Gateway.Observability;

public sealed class RedactionProcessor : BaseProcessor<Activity>
{
    private static readonly HashSet<string> SensitiveAttributes = new(StringComparer.OrdinalIgnoreCase)
    {
        "access_token",
        "authorization",
        "secret",
        "password",
        "prompt.content",
        "response.content"
    };

    private const string RedactedValue = "[REDACTED]";

    public override void OnEnd(Activity data)
    {
        foreach (var tag in data.TagObjects)
        {
            if (SensitiveAttributes.Contains(tag.Key))
            {
                data.SetTag(tag.Key, RedactedValue);
            }
        }
    }
}
