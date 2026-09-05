using System.Text;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.Api.Infrastructure;
using Gateway.Domain.Models;
using Gateway.Purview;
using Gateway.UnitTests.ProtectionApi;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using NSubstitute;

namespace Gateway.UnitTests.Purview;

public sealed class ManagedIdentityPurviewTokenProviderTests
{
    private static readonly Guid RuntimePrincipalId =
        Guid.Parse("11111111-1111-4111-8111-111111111111");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Constructor_RequiresRuntimeIdentityToMatchBootstrapAttestation(bool drift)
    {
        var options = Options.Create(new PurviewOptions { Enabled = true });
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["BootstrapCapabilities:Enabled"] = "true",
                ["BootstrapCapabilities:Purview:Status"] = "Installed",
                ["BootstrapCapabilities:Purview:PurviewRuntimeManagedIdentityPrincipalObjectId"] =
                    RuntimePrincipalId.ToString("D"),
                ["PurviewRuntimeIdentity:ManagedIdentityClientId"] = drift
                    ? "44444444-4444-4444-8444-444444444444"
                    : "33333333-3333-4333-8333-333333333333",
                ["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] = drift
                    ? "22222222-2222-4222-8222-222222222222"
                    : RuntimePrincipalId.ToString("D")
            })
            .Build();

        var bootstrap = BootstrapCapabilitiesOptionsTests.CreateValid();
        bootstrap.Purview.PurviewRuntimeManagedIdentityPrincipalObjectId = RuntimePrincipalId.ToString("D");
        var binding = new BootstrapPurviewRuntimeBinding(Options.Create(bootstrap), options, configuration);
        var action = () => new ManagedIdentityPurviewTokenProvider(options, configuration, binding);

        if (drift)
            action.Should().Throw<PurviewPolicyException>()
                .WithMessage("The Purview runtime identity does not match its bootstrap capability attestation.");
        else
            action.Should().NotThrow();
    }

    [Fact]
    public async Task GetTokenAsync_AcceptsTheExactConfiguredRuntimePrincipal()
    {
        var provider = new ManagedIdentityPurviewTokenProvider(
            new StubTokenCredential(CreateToken(RuntimePrincipalId)),
            RuntimePrincipalId);

        var result = await provider.GetTokenAsync(CancellationToken.None);

        result.ExpiresOn.Should().BeAfter(DateTimeOffset.UtcNow);
    }

    [Fact]
    public async Task GetTokenAsync_RechecksBindingBeforeAcquiringCredential()
    {
        var binding = Substitute.For<IPurviewRuntimeIdentityBinding>();
        const string clientId = "33333333-3333-4333-8333-333333333333";
        binding.IsExact(clientId, RuntimePrincipalId).Returns(true);
        var credential = new StubTokenCredential(CreateToken(RuntimePrincipalId));
        var provider = new ManagedIdentityPurviewTokenProvider(credential, RuntimePrincipalId, binding, clientId);
        await provider.GetTokenAsync(CancellationToken.None);
        credential.Calls.Should().Be(1);
        binding.IsExact(clientId, RuntimePrincipalId).Returns(false);

        var action = async () => await provider.GetTokenAsync(CancellationToken.None);

        (await action.Should().ThrowAsync<PurviewPolicyException>()).Which.FailureCode
            .Should().Be("PURVIEW_CAPABILITY_BINDING_INVALID");
        credential.Calls.Should().Be(1);
    }

    [Fact]
    public void WorkerProviderRetainsExplicitIdentityBindingWithoutApiBootstrapConfiguration()
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["PurviewRuntimeIdentity:ManagedIdentityClientId"] = "33333333-3333-4333-8333-333333333333",
            ["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] = RuntimePrincipalId.ToString("D")
        }).Build();
        var action = () => new ManagedIdentityPurviewTokenProvider(
            Options.Create(new PurviewOptions { Enabled = true }), configuration);

        action.Should().NotThrow();
    }

    [Fact]
    public async Task GetTokenAsync_RejectsAnotherManagedIdentityWithoutExposingCredential()
    {
        var token = CreateToken(Guid.Parse("22222222-2222-4222-8222-222222222222"));
        var provider = new ManagedIdentityPurviewTokenProvider(
            new StubTokenCredential(token),
            RuntimePrincipalId);

        var action = async () => await provider.GetTokenAsync(CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_TOKEN_SUBJECT_MISMATCH");
        exception.Which.Message.Should().NotContain(token.Token);
    }

    [Fact]
    public async Task GetTokenAsync_RejectsCredentialWithoutOneCanonicalSubject()
    {
        var token = CreateToken(principalObjectId: null);
        var provider = new ManagedIdentityPurviewTokenProvider(
            new StubTokenCredential(token),
            RuntimePrincipalId);

        var action = async () => await provider.GetTokenAsync(CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_TOKEN_SUBJECT_INVALID");
        exception.Which.Message.Should().NotContain(token.Token);
    }

    [Fact]
    public void Constructor_FailsClosedWhenEnabledRuntimeIdentityBindingIsMissing()
    {
        var options = Options.Create(new PurviewOptions { Enabled = true });
        var configuration = new ConfigurationBuilder().Build();

        var action = () =>
            new ManagedIdentityPurviewTokenProvider(options, configuration);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("The Purview runtime managed identity is not configured.");
    }

    [Fact]
    public void Constructor_FailsClosedWhenRuntimeIdentityBindingIsPartial()
    {
        var options = Options.Create(new PurviewOptions { Enabled = true });
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["PurviewRuntimeIdentity:ManagedIdentityClientId"] =
                    "33333333-3333-4333-8333-333333333333"
            })
            .Build();

        var action = () =>
            new ManagedIdentityPurviewTokenProvider(options, configuration);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("The Purview runtime managed-identity binding is incomplete.");
    }

    private static AccessToken CreateToken(Guid? principalObjectId)
    {
        var payload = principalObjectId is null
            ? JsonSerializer.SerializeToUtf8Bytes(new { roles = Array.Empty<string>() })
            : JsonSerializer.SerializeToUtf8Bytes(
                new { oid = principalObjectId.Value.ToString("D") });
        return new AccessToken(
            $"{Encode("{}"u8.ToArray())}.{Encode(payload)}.synthetic-signature",
            DateTimeOffset.UtcNow.AddMinutes(5));
    }

    private static string Encode(byte[] value) =>
        Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private sealed class StubTokenCredential(AccessToken token) : TokenCredential
    {
        public int Calls { get; private set; }

        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken) =>
            token;

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            Calls++;
            return ValueTask.FromResult(token);
        }
    }
}
