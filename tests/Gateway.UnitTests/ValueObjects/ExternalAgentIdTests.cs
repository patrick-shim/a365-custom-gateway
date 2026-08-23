using FluentAssertions;
using Gateway.Domain.ValueObjects;

namespace Gateway.UnitTests.ValueObjects;

public class ExternalAgentIdTests
{
    [Theory]
    [InlineData("my-agent-1")]
    [InlineData("Agent.Test_123")]
    [InlineData("abc")]
    [InlineData("agent123")]
    [InlineData("Agent-With.Mixed_Chars99")]
    public void Constructor_Should_Succeed_When_ValueIsValid(string value)
    {
        var id = new ExternalAgentId(value);

        id.Value.Should().Be(value);
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsNull()
    {
        var act = () => new ExternalAgentId(null!);

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsEmpty()
    {
        var act = () => new ExternalAgentId(string.Empty);

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsWhitespace()
    {
        var act = () => new ExternalAgentId("   ");

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsTooShort()
    {
        var act = () => new ExternalAgentId("ab");

        act.Should().Throw<ArgumentException>()
            .WithMessage("*between*3*128*");
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsTooLong()
    {
        var longValue = new string('a', 129);

        var act = () => new ExternalAgentId(longValue);

        act.Should().Throw<ArgumentException>()
            .WithMessage("*between*3*128*");
    }

    [Fact]
    public void Constructor_Should_Succeed_When_ValueIsExactlyMinLength()
    {
        var id = new ExternalAgentId("abc");

        id.Value.Should().Be("abc");
    }

    [Fact]
    public void Constructor_Should_Succeed_When_ValueIsExactlyMaxLength()
    {
        var maxValue = new string('a', 128);

        var id = new ExternalAgentId(maxValue);

        id.Value.Should().Be(maxValue);
    }

    [Theory]
    [InlineData("-agent")]
    [InlineData(".agent")]
    [InlineData("_agent")]
    public void Constructor_Should_ThrowArgumentException_When_ValueStartsWithInvalidChar(string value)
    {
        var act = () => new ExternalAgentId(value);

        act.Should().Throw<ArgumentException>()
            .WithMessage("*pattern*");
    }

    [Theory]
    [InlineData("agent@test")]
    [InlineData("agent test")]
    [InlineData("agent/test")]
    [InlineData("agent#test")]
    [InlineData("agent!test")]
    public void Constructor_Should_ThrowArgumentException_When_ValueContainsInvalidChars(string value)
    {
        var act = () => new ExternalAgentId(value);

        act.Should().Throw<ArgumentException>()
            .WithMessage("*pattern*");
    }

    [Fact]
    public void ToString_Should_ReturnValue()
    {
        var id = new ExternalAgentId("my-agent-1");

        id.ToString().Should().Be("my-agent-1");
    }

    [Fact]
    public void Equality_Should_BeTrue_When_ValuesAreEqual()
    {
        var id1 = new ExternalAgentId("my-agent-1");
        var id2 = new ExternalAgentId("my-agent-1");

        id1.Should().Be(id2);
        (id1 == id2).Should().BeTrue();
    }

    [Fact]
    public void Equality_Should_BeFalse_When_ValuesAreDifferent()
    {
        var id1 = new ExternalAgentId("agent-one");
        var id2 = new ExternalAgentId("agent-two");

        id1.Should().NotBe(id2);
        (id1 != id2).Should().BeTrue();
    }
}
