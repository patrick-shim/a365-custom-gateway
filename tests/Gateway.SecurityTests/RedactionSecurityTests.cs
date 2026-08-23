using System.Diagnostics;
using FluentAssertions;
using Gateway.Observability;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that the <see cref="RedactionProcessor"/> correctly redacts sensitive
/// telemetry attributes and preserves non-sensitive ones. This prevents accidental
/// leakage of tokens, passwords, and prompt/response content through observability
/// pipelines.
/// </summary>
public class RedactionSecurityTests : IDisposable
{
    private readonly ActivitySource _activitySource;
    private readonly ActivityListener _listener;

    public RedactionSecurityTests()
    {
        _activitySource = new ActivitySource("Gateway.SecurityTests.Redaction");
        _listener = new ActivityListener
        {
            ShouldListenTo = _ => true,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) =>
                ActivitySamplingResult.AllDataAndRecorded
        };
        ActivitySource.AddActivityListener(_listener);
    }

    // ---------------------------------------------------------------
    // Sensitive attribute redaction
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("access_token")]
    [InlineData("authorization")]
    [InlineData("secret")]
    [InlineData("password")]
    [InlineData("prompt.content")]
    [InlineData("response.content")]
    public void OnEnd_Should_RedactSensitiveAttribute_When_AttributeNameMatchesSensitiveList(
        string attributeName)
    {
        using var activity = _activitySource.StartActivity("test-redact-sensitive")!;
        activity.SetTag(attributeName, "sensitive-value-that-must-not-leak");

        var processor = new RedactionProcessor();
        processor.OnEnd(activity);

        activity.GetTagItem(attributeName).Should().Be("[REDACTED]");
    }

    // ---------------------------------------------------------------
    // Case-insensitive redaction
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Access_Token")]
    [InlineData("ACCESS_TOKEN")]
    [InlineData("AUTHORIZATION")]
    [InlineData("Authorization")]
    [InlineData("Password")]
    [InlineData("PASSWORD")]
    [InlineData("SECRET")]
    [InlineData("Secret")]
    [InlineData("Prompt.Content")]
    [InlineData("PROMPT.CONTENT")]
    [InlineData("Response.Content")]
    [InlineData("RESPONSE.CONTENT")]
    public void OnEnd_Should_RedactSensitiveAttribute_When_AttributeNameDiffersByCase(
        string attributeName)
    {
        using var activity = _activitySource.StartActivity("test-case-insensitive")!;
        activity.SetTag(attributeName, "case-variant-secret-value");

        var processor = new RedactionProcessor();
        processor.OnEnd(activity);

        activity.GetTagItem(attributeName).Should().Be("[REDACTED]",
            $"attribute '{attributeName}' should be redacted regardless of case");
    }

    // ---------------------------------------------------------------
    // Non-sensitive attribute preservation
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("operation.name", "MyOperation")]
    [InlineData("http.method", "POST")]
    [InlineData("user.id", "user-123")]
    [InlineData("http.status_code", "200")]
    [InlineData("db.statement", "SELECT 1")]
    [InlineData("agent.id", "agent-456")]
    [InlineData("http.url", "https://example.com/api/v1/agents")]
    [InlineData("correlation.id", "abc-def-ghi")]
    public void OnEnd_Should_PreserveNonSensitiveAttribute_When_AttributeIsNotInSensitiveList(
        string attributeName, string attributeValue)
    {
        using var activity = _activitySource.StartActivity("test-preserve")!;
        activity.SetTag(attributeName, attributeValue);

        var processor = new RedactionProcessor();
        processor.OnEnd(activity);

        activity.GetTagItem(attributeName).Should().Be(attributeValue,
            $"non-sensitive attribute '{attributeName}' must not be modified");
    }

    // ---------------------------------------------------------------
    // Redacted value is exactly "[REDACTED]"
    // ---------------------------------------------------------------

    [Fact]
    public void OnEnd_Should_SetRedactedValueToExactMarkerString_When_Redacting()
    {
        using var activity = _activitySource.StartActivity("test-exact-marker")!;
        activity.SetTag("access_token", "bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...");

        var processor = new RedactionProcessor();
        processor.OnEnd(activity);

        var redactedValue = activity.GetTagItem("access_token");

        redactedValue.Should().NotBeNull("redacted value must not be null");
        redactedValue.Should().NotBe(string.Empty, "redacted value must not be empty string");
        redactedValue.Should().BeOfType<string>();
        redactedValue.Should().Be("[REDACTED]",
            "the exact redaction marker must be the string '[REDACTED]'");
    }

    // ---------------------------------------------------------------
    // Multiple sensitive attributes in single activity
    // ---------------------------------------------------------------

    [Fact]
    public void OnEnd_Should_RedactAllSensitiveAttributes_When_ActivityHasMultiple()
    {
        using var activity = _activitySource.StartActivity("test-multiple")!;
        activity.SetTag("access_token", "token-value");
        activity.SetTag("password", "pass-value");
        activity.SetTag("prompt.content", "user prompt text should not leak");
        activity.SetTag("response.content", "AI response text should not leak");
        activity.SetTag("operation.name", "safe-value");
        activity.SetTag("http.method", "POST");

        var processor = new RedactionProcessor();
        processor.OnEnd(activity);

        // Sensitive attributes redacted
        activity.GetTagItem("access_token").Should().Be("[REDACTED]");
        activity.GetTagItem("password").Should().Be("[REDACTED]");
        activity.GetTagItem("prompt.content").Should().Be("[REDACTED]");
        activity.GetTagItem("response.content").Should().Be("[REDACTED]");

        // Non-sensitive attributes preserved
        activity.GetTagItem("operation.name").Should().Be("safe-value");
        activity.GetTagItem("http.method").Should().Be("POST");
    }

    // ---------------------------------------------------------------
    // Activity with no sensitive attributes is unchanged
    // ---------------------------------------------------------------

    [Fact]
    public void OnEnd_Should_NotModifyAnyAttributes_When_NoSensitiveAttributesPresent()
    {
        using var activity = _activitySource.StartActivity("test-no-sensitive")!;
        activity.SetTag("operation.name", "SomeOperation");
        activity.SetTag("http.status_code", "200");
        activity.SetTag("user.id", "user-abc");

        var processor = new RedactionProcessor();
        processor.OnEnd(activity);

        activity.GetTagItem("operation.name").Should().Be("SomeOperation");
        activity.GetTagItem("http.status_code").Should().Be("200");
        activity.GetTagItem("user.id").Should().Be("user-abc");
    }

    // ---------------------------------------------------------------
    // Cleanup
    // ---------------------------------------------------------------

    public void Dispose()
    {
        _activitySource.Dispose();
        _listener.Dispose();
    }
}
