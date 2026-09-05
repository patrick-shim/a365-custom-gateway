using FluentAssertions;
using Gateway.Provisioning.Worker;

namespace Gateway.ObservabilityRuntime.Tests.ProtectionAdmin;

public sealed class PurviewConnectionVerificationProviderTests
{
    [Fact]
    public void EvidenceDigest_IsCanonicalDeterministicAndOperationBound()
    {
        var operationId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var administratorId = Guid.NewGuid();
        var applicationId = Guid.NewGuid();
        var observedAt = new DateTimeOffset(
            2026,
            9,
            5,
            11,
            0,
            0,
            TimeSpan.Zero);
        PurviewConnectionInventoryItem[] items =
        [
            new(Guid.NewGuid(), "Zulu type", "Contoso", 8),
            new(Guid.NewGuid(), "Alpha type", "Microsoft", 4)
        ];

        var first = PurviewConnectionVerificationEvidence.Create(
            operationId,
            tenantId,
            administratorId,
            applicationId,
            ServicePrincipalId,
            KeyVaultResourceId,
            KeyVaultHost,
            CertificateName,
            CertificateSecretUri,
            ProviderCertificateSecretId,
            observedAt,
            observedAt.AddMinutes(15),
            items);
        var reordered = PurviewConnectionVerificationEvidence.Create(
            operationId,
            tenantId,
            administratorId,
            applicationId,
            ServicePrincipalId,
            KeyVaultResourceId,
            KeyVaultHost,
            CertificateName,
            CertificateSecretUri,
            ProviderCertificateSecretId,
            observedAt.AddSeconds(5),
            observedAt.AddMinutes(10),
            items.Reverse().ToArray());
        var anotherOperation = PurviewConnectionVerificationEvidence.Create(
            Guid.NewGuid(),
            tenantId,
            administratorId,
            applicationId,
            ServicePrincipalId,
            KeyVaultResourceId,
            KeyVaultHost,
            CertificateName,
            CertificateSecretUri,
            ProviderCertificateSecretId,
            observedAt,
            observedAt.AddMinutes(15),
            items);

        first.EvidenceDigest.Should().Be(reordered.EvidenceDigest);
        first.InventoryGenerationId.Should().Be(reordered.InventoryGenerationId);
        first.Items.Select(item => item.SortOrder).Should().Equal(0, 1);
        first.HasValidDigestAndGeneration().Should().BeTrue();
        anotherOperation.InventoryGenerationId.Should()
            .NotBe(first.InventoryGenerationId);
    }

    [Fact]
    public void EvidenceDigest_TamperingFailsValidation()
    {
        var observedAt = DateTimeOffset.UtcNow;
        var evidence = PurviewConnectionVerificationEvidence.Create(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            ServicePrincipalId,
            KeyVaultResourceId,
            KeyVaultHost,
            CertificateName,
            CertificateSecretUri,
            ProviderCertificateSecretId,
            observedAt,
            observedAt.AddMinutes(15),
            [
                new(
                    Guid.NewGuid(),
                    "Synthetic identifier",
                    "Contoso",
                    SortOrder: 0)
            ]);

        (evidence with
        {
            EvidenceDigest =
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }).HasValidDigestAndGeneration().Should().BeFalse();
        (evidence with
        {
            InventoryGenerationId = Guid.NewGuid()
        }).HasValidDigestAndGeneration().Should().BeFalse();
    }

    [Fact]
    public async Task CallerCancellation_KillsProcessTreeAndCleansTemporaryMaterial()
    {
        var temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"a365gw-verifier-cancellation-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temporaryDirectory);
        await File.WriteAllTextAsync(
            Path.Combine(temporaryDirectory, "temporary.bin"),
            "cleanup-marker");
        var process = new RecordingProcessControl();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        try
        {
            var action = () =>
                PowerShellPurviewConnectionVerificationProvider
                    .WaitForExitOrCancelAsync(
                        process,
                        temporaryDirectory,
                        cancellation.Token,
                        cancellation.Token);

            var exception = await action.Should()
                .ThrowAsync<OperationCanceledException>();

            exception.Which.CancellationToken.Should().Be(cancellation.Token);
            process.KillEntireTree.Should().BeTrue();
            process.WaitCalls.Should().Be(2);
            Directory.Exists(temporaryDirectory).Should().BeFalse();
        }
        finally
        {
            if (Directory.Exists(temporaryDirectory))
                Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    private sealed class RecordingProcessControl : IPurviewVerifierProcessControl
    {
        public bool HasExited { get; private set; }
        public bool KillEntireTree { get; private set; }
        public int WaitCalls { get; private set; }

        public void Kill(bool entireProcessTree)
        {
            KillEntireTree = entireProcessTree;
            HasExited = true;
        }

        public Task WaitForExitAsync(CancellationToken cancellationToken)
        {
            WaitCalls++;
            return HasExited
                ? Task.CompletedTask
                : Task.FromCanceled(cancellationToken);
        }
    }

    private static readonly Guid ServicePrincipalId =
        Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    private const string KeyVaultResourceId =
        "/subscriptions/cccccccc-cccc-4ccc-8ccc-cccccccccccc/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gatewayvault";
    private const string KeyVaultHost = "gatewayvault.vault.azure.net";
    private const string CertificateName = "purview-automation";
    private static readonly Uri CertificateSecretUri =
        new("https://gatewayvault.vault.azure.net/secrets/purview-automation");
    private static readonly Uri ProviderCertificateSecretId =
        new("https://gatewayvault.vault.azure.net/secrets/purview-automation/version");
}
