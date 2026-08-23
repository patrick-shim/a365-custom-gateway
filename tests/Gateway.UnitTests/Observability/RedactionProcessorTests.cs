using System.Diagnostics;
using FluentAssertions;
using Gateway.Observability;

namespace Gateway.UnitTests.Observability;

public class RedactionProcessorTests
{
    private readonly RedactionProcessor _processor = new();

    [Theory]
    [InlineData("access_token")]
    [InlineData("authorization")]
    [InlineData("secret")]
    [InlineData("password")]
    [InlineData("prompt.content")]
    [InlineData("response.content")]
    public void OnEnd_Should_RedactSensitiveTag(string tagKey)
    {
        var activity = new Activity("test-operation");
        activity.SetTag(tagKey, "sensitive-value-that-should-be-redacted");

        _processor.OnEnd(activity);

        activity.GetTagItem(tagKey).Should().Be("[REDACTED]");
    }

    [Theory]
    [InlineData("Access_Token")]
    [InlineData("AUTHORIZATION")]
    [InlineData("Secret")]
    [InlineData("PASSWORD")]
    [InlineData("Prompt.Content")]
    [InlineData("RESPONSE.CONTENT")]
    public void OnEnd_Should_RedactSensitiveTag_CaseInsensitive(string tagKey)
    {
        var activity = new Activity("test-operation");
        activity.SetTag(tagKey, "sensitive-value");

        _processor.OnEnd(activity);

        activity.GetTagItem(tagKey).Should().Be("[REDACTED]");
    }

    [Theory]
    [InlineData("http.method")]
    [InlineData("http.url")]
    [InlineData("service.name")]
    [InlineData("agent.id")]
    [InlineData("operation.type")]
    public void OnEnd_Should_NotRedactNonSensitiveTag(string tagKey)
    {
        var activity = new Activity("test-operation");
        activity.SetTag(tagKey, "safe-value");

        _processor.OnEnd(activity);

        activity.GetTagItem(tagKey).Should().Be("safe-value");
    }

    [Fact]
    public void OnEnd_Should_RedactMultipleSensitiveTags_And_PreserveNonSensitive()
    {
        var activity = new Activity("test-operation");
        activity.SetTag("access_token", "bearer-token-123");
        activity.SetTag("password", "super-secret");
        activity.SetTag("http.method", "POST");
        activity.SetTag("service.name", "gateway");
        activity.SetTag("prompt.content", "Tell me about...");

        _processor.OnEnd(activity);

        activity.GetTagItem("access_token").Should().Be("[REDACTED]");
        activity.GetTagItem("password").Should().Be("[REDACTED]");
        activity.GetTagItem("prompt.content").Should().Be("[REDACTED]");
        activity.GetTagItem("http.method").Should().Be("POST");
        activity.GetTagItem("service.name").Should().Be("gateway");
    }

    [Fact]
    public void OnEnd_Should_HandleActivityWithNoTags()
    {
        var activity = new Activity("test-operation");

        var act = () => _processor.OnEnd(activity);

        act.Should().NotThrow();
    }
}
