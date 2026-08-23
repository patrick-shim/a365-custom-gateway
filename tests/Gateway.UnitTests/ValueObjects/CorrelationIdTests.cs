using FluentAssertions;
using Gateway.Domain.ValueObjects;

namespace Gateway.UnitTests.ValueObjects;

public class CorrelationIdTests
{
    [Fact]
    public void Constructor_Should_CreateInstance_When_GuidIsValid()
    {
        var guid = Guid.NewGuid();

        var correlationId = new CorrelationId(guid);

        correlationId.Value.Should().Be(guid);
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_GuidIsEmpty()
    {
        var act = () => new CorrelationId(Guid.Empty);

        act.Should().Throw<ArgumentException>()
            .WithMessage("*cannot be empty*");
    }

    [Fact]
    public void NewCorrelationId_Should_CreateNonEmptyValue()
    {
        var correlationId = CorrelationId.NewCorrelationId();

        correlationId.Value.Should().NotBe(Guid.Empty);
    }

    [Fact]
    public void NewCorrelationId_Should_CreateUniqueValues()
    {
        var id1 = CorrelationId.NewCorrelationId();
        var id2 = CorrelationId.NewCorrelationId();

        id1.Should().NotBe(id2);
    }

    [Fact]
    public void ToString_Should_ReturnGuidString()
    {
        var guid = Guid.NewGuid();
        var correlationId = new CorrelationId(guid);

        correlationId.ToString().Should().Be(guid.ToString());
    }

    [Fact]
    public void Equality_Should_BeTrue_When_ValuesAreEqual()
    {
        var guid = Guid.NewGuid();
        var id1 = new CorrelationId(guid);
        var id2 = new CorrelationId(guid);

        id1.Should().Be(id2);
        (id1 == id2).Should().BeTrue();
    }

    [Fact]
    public void Equality_Should_BeFalse_When_ValuesAreDifferent()
    {
        var id1 = new CorrelationId(Guid.NewGuid());
        var id2 = new CorrelationId(Guid.NewGuid());

        id1.Should().NotBe(id2);
        (id1 != id2).Should().BeTrue();
    }
}
