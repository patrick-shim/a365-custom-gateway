using System.Text.Json;
using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class PurviewSensitiveInformationTypeDiscoveryTests
{
    [Fact]
    public async Task DiscoverAsync_UnsupportedPlatformStopsBeforeAzureOrPowerShell()
    {
        var azure = new StubAzureCliRunner();
        var purview = new StubPurviewRunner(isSupported: false);
        var discovery = new PurviewSensitiveInformationTypeDiscovery(azure, purview);

        var result = await discovery.DiscoverAsync(Guid.NewGuid(), Guid.NewGuid());

        discovery.IsSupported.Should().BeFalse();
        discovery.UnsupportedGuidance.Should().Be(
            PurviewSensitiveInformationTypeDiscovery.UnsupportedPlatformGuidance);
        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Be(
            PurviewSensitiveInformationTypeDiscovery.UnsupportedPlatformGuidance);
        result.Guidance.Should().ContainAll("Microsoft", "macOS", "Linux", "Windows");
        azure.Calls.Should().BeEmpty();
        purview.Calls.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_BindsExactAzureTargetGraphUserAndTenantInventory()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var firstId = Guid.Parse("11111111-1111-4111-8111-111111111111");
        var secondId = Guid.Parse("22222222-2222-4222-8222-222222222222");
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(GraphMeJson(Guid.NewGuid(), "operator@contoso.example")));
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = secondId, name = "주민등록번호", publisher = "Contoso" },
            new { id = firstId, name = "Credit Card Number", publisher = "Microsoft Corporation" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeTrue();
        result.SubscriptionId.Should().Be(subscriptionId);
        result.TenantId.Should().Be(tenantId);
        result.Types.Select(type => type.Id).Should().Equal(firstId, secondId);
        result.Types[1].Name.Should().Be("주민등록번호");
        result.Types[1].Publisher.Should().Be("Contoso");
        azure.Calls.Should().HaveCount(2);
        azure.Calls[0].Should().ContainInOrder(
            "account",
            "show",
            "--subscription",
            subscriptionId.ToString("D"));
        azure.Calls[1].Should().ContainInOrder(
            "rest",
            "--method",
            "GET",
            "--url",
            "https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,userType",
            "--resource",
            "https://graph.microsoft.com/",
            "--subscription",
            subscriptionId.ToString("D"));
        purview.Calls.Should().ContainSingle().Which.Should().Be(
            new PurviewRunnerCall(tenantId, "operator@contoso.example"));
    }

    [Fact]
    public async Task DiscoverAsync_RejectsWrongAzureTenantBeforeGraphOrPowerShell()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, Guid.NewGuid(), "Enabled")));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("exact selected subscription and tenant");
        azure.Calls.Should().ContainSingle();
        purview.Calls.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_RejectsGraphUpnThatWouldChangeWhenTrimmed()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(GraphMeJson(Guid.NewGuid(), " operator@contoso.example")));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("signed-in Microsoft Graph user");
        purview.Calls.Should().BeEmpty();
    }

    [Theory]
    [InlineData("Guest")]
    [InlineData("member")]
    public async Task DiscoverAsync_RejectsNonMemberGraphUserBeforePowerShell(string userType)
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(GraphMeJson(Guid.NewGuid(), "operator@contoso.example", userType)));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("userType Member");
        purview.Calls.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_RejectsMissingGraphUserTypeBeforePowerShell()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new
            {
                id = Guid.NewGuid(),
                userPrincipalName = "operator@contoso.example"
            })));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("unexpected signed-in Microsoft Graph user response");
        purview.Calls.Should().BeEmpty();
    }

    [Theory]
    [InlineData("ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")]
    [InlineData("{abcdefab-cdef-4abc-8def-abcdefabcdef}")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    [InlineData("not-a-guid")]
    public async Task DiscoverAsync_RejectsNoncanonicalOrInvalidGraphObjectIdBeforePowerShell(
        string objectId)
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new
            {
                id = objectId,
                userPrincipalName = "operator@contoso.example",
                userType = "Member"
            })));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("unexpected signed-in Microsoft Graph user response");
        purview.Calls.Should().BeEmpty();
    }

    [Theory]
    [InlineData("member")]
    [InlineData("member@contoso")]
    [InlineData(" member@contoso.example")]
    [InlineData("member@contoso.example ")]
    [InlineData("member\u0007@contoso.example")]
    [InlineData("member\u200D@contoso.example")]
    [InlineData(null)]
    public async Task DiscoverAsync_RejectsMalformedGraphUpnBeforePowerShell(string? userPrincipalName)
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new
            {
                id = "abcdefab-cdef-4abc-8def-abcdefabcdef",
                userPrincipalName,
                userType = "Member"
            })));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("unexpected signed-in Microsoft Graph user response");
        purview.Calls.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_RejectsMissingGraphUpnBeforePowerShell()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new
            {
                id = "abcdefab-cdef-4abc-8def-abcdefabcdef",
                userType = "Member"
            })));
        var purview = new StubPurviewRunner();

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("unexpected signed-in Microsoft Graph user response");
        purview.Calls.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_RejectsHelperEnvelopeForAnotherTenant()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            Guid.NewGuid(),
            new { id = Guid.NewGuid(), name = "Credit Card Number", publisher = "Microsoft" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
        result.Guidance.Should().Contain("unexpected tenant inventory");
    }

    [Fact]
    public async Task DiscoverAsync_RejectsDuplicateGuidWithoutChoosingOne()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var duplicateId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = duplicateId, name = "First", publisher = "Contoso" },
            new { id = duplicateId, name = "Second", publisher = "Contoso" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
        result.Guidance.Should().Contain("unexpected tenant inventory");
    }

    [Fact]
    public async Task DiscoverAsync_RejectsDuplicateExactNameWithDifferentGuids()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = Guid.NewGuid(), name = "Credit Card Number", publisher = "Microsoft" },
            new { id = Guid.NewGuid(), name = "Credit Card Number", publisher = "Contoso" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
        result.Guidance.Should().Contain("unexpected tenant inventory");
    }

    [Fact]
    public async Task DiscoverAsync_RejectsEmptyInventoryWithoutSelectingADefault()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(tenantId)));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_RejectsInventoryBeyondTheExactBound()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var types = Enumerable.Range(0, 2049)
            .Select(index => (object)new
            {
                id = Guid.NewGuid(),
                name = $"Type {index:D4}",
                publisher = "Contoso"
            })
            .ToArray();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(tenantId, types)));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
    }

    [Theory]
    [InlineData(" Credit Card Number")]
    [InlineData("Credit Card Number ")]
    [InlineData("Credit\nCard Number")]
    public async Task DiscoverAsync_RejectsNamesThatWouldBeNormalizedOrContainControls(string name)
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = Guid.NewGuid(), name, publisher = "Contoso" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
    }

    [Fact]
    public async Task DiscoverAsync_RejectsPublisherThatWouldChangeWhenTrimmed()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = Guid.NewGuid(), name = "Credit Card Number", publisher = " Microsoft" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Types.Should().BeEmpty();
    }

    [Theory]
    [InlineData(255, true)]
    [InlineData(256, false)]
    public async Task DiscoverAsync_EnforcesExactUnicodeNameLengthBound(
        int length,
        bool expectedSuccess)
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = Guid.NewGuid(), name = new string('가', length), publisher = "Contoso" })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().Be(expectedSuccess);
        result.Types.Should().HaveCount(expectedSuccess ? 1 : 0);
    }

    [Theory]
    [InlineData(200, true)]
    [InlineData(201, false)]
    public async Task DiscoverAsync_EnforcesExactPublisherLengthBound(
        int length,
        bool expectedSuccess)
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(CompletedPurview(InventoryJson(
            tenantId,
            new { id = Guid.NewGuid(), name = "Credit Card Number", publisher = new string('P', length) })));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().Be(expectedSuccess);
        result.Types.Should().HaveCount(expectedSuccess ? 1 : 0);
    }

    [Fact]
    public async Task DiscoverAsync_WithHelperFailureWithholdsOutputDetails()
    {
        const string sentinel = "provider-body-sentinel-must-not-render";
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new StubPurviewRunner(new PurviewSensitiveInformationTypeInvocationResult(
            PurviewSensitiveInformationTypeInvocationStatus.Completed,
            1,
            sentinel));

        var result = await new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().NotContain(sentinel);
        result.Guidance.Should().Contain("Security & Compliance PowerShell");
    }

    [Fact]
    public async Task DiscoverAsync_PropagatesCallerCancellation()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var azure = ReadyAzure(subscriptionId, tenantId);
        var purview = new CancellingPurviewRunner();

        var action = () => new PurviewSensitiveInformationTypeDiscovery(azure, purview)
            .DiscoverAsync(subscriptionId, tenantId, new CancellationToken(canceled: true));

        await action.Should().ThrowAsync<OperationCanceledException>();
    }

    private static StubAzureCliRunner ReadyAzure(Guid subscriptionId, Guid tenantId) => new(
        Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
        Completed(GraphMeJson(Guid.NewGuid(), "operator@contoso.example")));

    private static AzureCliInvocationResult Completed(string output) => new(
        AzureCliInvocationStatus.Completed,
        0,
        output);

    private static PurviewSensitiveInformationTypeInvocationResult CompletedPurview(string output) => new(
        PurviewSensitiveInformationTypeInvocationStatus.Completed,
        0,
        output);

    private static string AccountJson(Guid subscriptionId, Guid tenantId, string state) =>
        JsonSerializer.Serialize(new { id = subscriptionId, tenantId, state });

    private static string GraphMeJson(
        Guid objectId,
        string userPrincipalName,
        string userType = "Member") =>
        JsonSerializer.Serialize(new { id = objectId, userPrincipalName, userType });

    private static string InventoryJson(Guid tenantId, params object[] types) =>
        JsonSerializer.Serialize(new { schemaVersion = 1, tenantId, types });

    private sealed class StubAzureCliRunner(params AzureCliInvocationResult[] results) : IAzureCliRunner
    {
        private readonly Queue<AzureCliInvocationResult> results = new(results);

        public List<IReadOnlyList<string>> Calls { get; } = [];

        public Task<AzureCliInvocationResult> RunAsync(
            IReadOnlyList<string> arguments,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add(arguments.ToArray());
            return Task.FromResult(results.Dequeue());
        }
    }

    private sealed class StubPurviewRunner
        : IPurviewSensitiveInformationTypeRunner
    {
        private readonly Queue<PurviewSensitiveInformationTypeInvocationResult> results;

        public StubPurviewRunner(
            params PurviewSensitiveInformationTypeInvocationResult[] results)
            : this(isSupported: true, results)
        {
        }

        public StubPurviewRunner(
            bool isSupported,
            params PurviewSensitiveInformationTypeInvocationResult[] results)
        {
            IsSupported = isSupported;
            this.results = new Queue<PurviewSensitiveInformationTypeInvocationResult>(results);
        }

        public bool IsSupported { get; }

        public List<PurviewRunnerCall> Calls { get; } = [];

        public Task<PurviewSensitiveInformationTypeInvocationResult> RunAsync(
            Guid tenantId,
            string userPrincipalName,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls.Add(new PurviewRunnerCall(tenantId, userPrincipalName));
            return Task.FromResult(results.Dequeue());
        }
    }

    private sealed class CancellingPurviewRunner : IPurviewSensitiveInformationTypeRunner
    {
        public bool IsSupported => true;

        public Task<PurviewSensitiveInformationTypeInvocationResult> RunAsync(
            Guid tenantId,
            string userPrincipalName,
            TimeSpan timeout,
            CancellationToken cancellationToken) =>
            Task.FromCanceled<PurviewSensitiveInformationTypeInvocationResult>(cancellationToken);
    }
}

internal sealed record PurviewRunnerCall(Guid TenantId, string UserPrincipalName);
