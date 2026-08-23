using FluentAssertions;
using Gateway.Domain.ValueObjects;

namespace Gateway.UnitTests.ValueObjects;

public class KeyVaultSecretUriTests
{
    [Fact]
    public void Constructor_Should_CreateInstance_When_UriIsValid()
    {
        const string uri = "https://myvault.vault.azure.net/secrets/mykey";

        var kvUri = new KeyVaultSecretUri(uri);

        kvUri.Value.Should().Be(uri);
    }

    [Theory]
    [InlineData("https://myvault.vault.azure.net/secrets/mykey")]
    [InlineData("https://another-vault.vault.azure.net/secrets/secret-name/version")]
    [InlineData("https://MYVAULT.VAULT.AZURE.NET/secrets/mykey")]
    public void Constructor_Should_Succeed_When_UriIsValidAzureKeyVault(string uri)
    {
        var kvUri = new KeyVaultSecretUri(uri);

        kvUri.Value.Should().Be(uri);
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsNull()
    {
        var act = () => new KeyVaultSecretUri(null!);

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsEmpty()
    {
        var act = () => new KeyVaultSecretUri(string.Empty);

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_ValueIsWhitespace()
    {
        var act = () => new KeyVaultSecretUri("   ");

        act.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_SchemeIsNotHttps()
    {
        var act = () => new KeyVaultSecretUri("http://myvault.vault.azure.net/secrets/mykey");

        act.Should().Throw<ArgumentException>()
            .WithMessage("*HTTPS*");
    }

    [Fact]
    public void Constructor_Should_ThrowArgumentException_When_DomainIsNotAzureKeyVault()
    {
        var act = () => new KeyVaultSecretUri("https://myvault.example.com/secrets/mykey");

        act.Should().Throw<ArgumentException>()
            .WithMessage("*.vault.azure.net*");
    }

    [Fact]
    public void ToString_Should_ReturnValue()
    {
        const string uri = "https://myvault.vault.azure.net/secrets/mykey";
        var kvUri = new KeyVaultSecretUri(uri);

        kvUri.ToString().Should().Be(uri);
    }

    [Fact]
    public void Equality_Should_BeTrue_When_ValuesAreEqual()
    {
        const string uri = "https://myvault.vault.azure.net/secrets/mykey";
        var uri1 = new KeyVaultSecretUri(uri);
        var uri2 = new KeyVaultSecretUri(uri);

        uri1.Should().Be(uri2);
    }
}
