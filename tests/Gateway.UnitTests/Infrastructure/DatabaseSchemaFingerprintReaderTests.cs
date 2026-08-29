using FluentAssertions;
using Gateway.Infrastructure.Persistence;

namespace Gateway.UnitTests.Infrastructure;

public sealed class DatabaseSchemaFingerprintReaderTests
{
    [Fact]
    public void Fingerprint_IsStableForTheExactOrderedSurface()
    {
        var first = DatabaseSchemaFingerprintReader.ComputeFingerprintForTesting(
            ["tables", "columns", "constraints"]);
        var second = DatabaseSchemaFingerprintReader.ComputeFingerprintForTesting(
            ["tables", "columns", "constraints"]);

        first.Should().Be(second).And.MatchRegex("^sha256:[0-9a-f]{64}$");
    }

    [Theory]
    [InlineData("table-drift", "columns", "constraints")]
    [InlineData("tables", "column-drift", "constraints")]
    [InlineData("tables", "columns", "permission-drift")]
    public void Fingerprint_ChangesForAnyCatalogSurfaceDrift(
        string first,
        string second,
        string third)
    {
        var baseline = DatabaseSchemaFingerprintReader.ComputeFingerprintForTesting(
            ["tables", "columns", "constraints"]);

        DatabaseSchemaFingerprintReader.ComputeFingerprintForTesting([first, second, third])
            .Should().NotBe(baseline);
    }
}
