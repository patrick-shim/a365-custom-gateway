using System.Text.Json;
using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class AzureAccountDiscoveryTests
{
    [Fact]
    public async Task DiscoverAsync_RequestsAllSubscriptionsAndPreservesDisabledRows()
    {
        var enabledId = Guid.NewGuid();
        var disabledId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var runner = new StubAzureCliRunner(Completed(JsonSerializer.Serialize(new object[]
        {
            new
            {
                name = "Disabled default",
                id = disabledId,
                tenantId,
                isDefault = true,
                state = "Disabled"
            },
            new
            {
                name = "Enabled target",
                id = enabledId,
                tenantId,
                isDefault = false,
                state = "Enabled"
            }
        })));

        var result = await new AzureAccountDiscovery(runner).DiscoverAsync();

        result.Succeeded.Should().BeTrue();
        result.Subscriptions.Select(subscription => subscription.SubscriptionId)
            .Should().Equal(enabledId, disabledId);
        result.Subscriptions[1].State.Should().Be("Disabled");
        runner.Calls.Should().ContainSingle();
        runner.Calls[0].Should().ContainInOrder("account", "list", "--all");
    }

    [Fact]
    public async Task DiscoverManagerApplicationsAsync_DerivesBoundedCandidatesWithVisibleProvenance()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var managerId = Guid.NewGuid();
        var servicePrincipalObjectId = Guid.NewGuid();
        var firstBlueprint = Guid.NewGuid();
        var secondBlueprint = Guid.NewGuid();
        var runner = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new
            {
                value = new object[]
                {
                    new
                    {
                        id = firstBlueprint,
                        displayName = "First blueprint",
                        managerApplications = new[] { managerId }
                    },
                    new
                    {
                        id = secondBlueprint,
                        displayName = "Second blueprint",
                        managerApplications = new[] { managerId }
                    }
                }
            })),
            Completed(ServicePrincipalJson(
                managerId,
                servicePrincipalObjectId,
                "Microsoft 365 App Catalog Services")));

        var result = await new AzureAccountDiscovery(runner)
            .DiscoverManagerApplicationsAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeTrue();
        result.Provenance.Should().Be(AzureAccountDiscovery.ManagerApplicationProvenance);
        result.Candidates.Should().ContainSingle();
        var candidate = result.Candidates[0];
        candidate.ApplicationId.Should().Be(managerId);
        candidate.ServicePrincipalObjectId.Should().Be(servicePrincipalObjectId);
        candidate.DisplayName.Should().Be("Microsoft 365 App Catalog Services");
        candidate.BlueprintReferenceCount.Should().Be(2);
        candidate.ReferencingBlueprintNames.Should().Equal("First blueprint", "Second blueprint");

        runner.Calls.Should().HaveCount(3);
        runner.Calls[0].Should().ContainInOrder(
            "account",
            "show",
            "--subscription",
            subscriptionId.ToString("D"));
        runner.Calls.Skip(1).Should().OnlyContain(arguments =>
            arguments.Contains("--resource") &&
            arguments.Contains("https://graph.microsoft.com/") &&
            arguments.Contains("--subscription") &&
            arguments.Contains(subscriptionId.ToString("D")) &&
            !arguments.Any(argument => argument.Contains("token", StringComparison.OrdinalIgnoreCase)));
    }

    [Fact]
    public async Task DiscoverManagerApplicationsAsync_RejectsDisabledSelectedSubscriptionBeforeGraph()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var runner = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Disabled")));

        var result = await new AzureAccountDiscovery(runner)
            .DiscoverManagerApplicationsAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("not Enabled");
        result.Candidates.Should().BeEmpty();
        runner.Calls.Should().ContainSingle();
    }

    [Fact]
    public async Task DiscoverManagerApplicationsAsync_RejectsOffOriginContinuationWithoutFollowingIt()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var managerId = Guid.NewGuid();
        var runner = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["value"] = new object[]
                {
                    new
                    {
                        id = Guid.NewGuid(),
                        displayName = "Blueprint",
                        managerApplications = new[] { managerId }
                    }
                },
                ["@odata.nextLink"] = "https://example.invalid/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$skiptoken=x"
            })));

        var result = await new AzureAccountDiscovery(runner)
            .DiscoverManagerApplicationsAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("bounded response contract");
        result.Candidates.Should().BeEmpty();
        runner.Calls.Should().HaveCount(2);
    }

    [Fact]
    public async Task DiscoverManagerApplicationsAsync_DoesNotGuessWhenBlueprintInventoryHasNoManagers()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var runner = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(JsonSerializer.Serialize(new
            {
                value = new[]
                {
                    new
                    {
                        id = Guid.NewGuid(),
                        displayName = "Blueprint without provider manager",
                        managerApplications = Array.Empty<Guid>()
                    }
                }
            })));

        var result = await new AzureAccountDiscovery(runner)
            .DiscoverManagerApplicationsAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("will not guess");
        result.Candidates.Should().BeEmpty();
        runner.Calls.Should().HaveCount(2);
    }

    [Fact]
    public async Task DiscoverManagerApplicationsAsync_RejectsAmbiguousServicePrincipalReadback()
    {
        var subscriptionId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var managerId = Guid.NewGuid();
        var runner = new StubAzureCliRunner(
            Completed(AccountJson(subscriptionId, tenantId, "Enabled")),
            Completed(BlueprintJson(managerId)),
            Completed(JsonSerializer.Serialize(new
            {
                value = new object[]
                {
                    ServicePrincipalShape(managerId, Guid.NewGuid(), "First"),
                    ServicePrincipalShape(managerId, Guid.NewGuid(), "Second")
                }
            })));

        var result = await new AzureAccountDiscovery(runner)
            .DiscoverManagerApplicationsAsync(subscriptionId, tenantId);

        result.Succeeded.Should().BeFalse();
        result.Guidance.Should().Contain("bounded response contract");
        result.Candidates.Should().BeEmpty();
    }

    private static AzureCliInvocationResult Completed(string output) => new(
        AzureCliInvocationStatus.Completed,
        0,
        output);

    private static string AccountJson(Guid subscriptionId, Guid tenantId, string state) =>
        JsonSerializer.Serialize(new { id = subscriptionId, tenantId, state });

    private static string BlueprintJson(Guid managerId) =>
        JsonSerializer.Serialize(new
        {
            value = new[]
            {
                new
                {
                    id = Guid.NewGuid(),
                    displayName = "Existing blueprint",
                    managerApplications = new[] { managerId }
                }
            }
        });

    private static string ServicePrincipalJson(
        Guid appId,
        Guid objectId,
        string displayName) =>
        JsonSerializer.Serialize(new
        {
            value = new[] { ServicePrincipalShape(appId, objectId, displayName) }
        });

    private static object ServicePrincipalShape(Guid appId, Guid objectId, string displayName) => new
    {
        id = objectId,
        appId,
        displayName,
        publisherName = "Microsoft Services",
        verifiedPublisher = new { displayName = "Microsoft" },
        servicePrincipalType = "Application"
    };

    private sealed class StubAzureCliRunner(params AzureCliInvocationResult[] results) : IAzureCliRunner
    {
        private readonly Queue<AzureCliInvocationResult> results = new(results);

        public List<IReadOnlyList<string>> Calls { get; } = [];

        public Task<AzureCliInvocationResult> RunAsync(
            IReadOnlyList<string> arguments,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            Calls.Add(arguments.ToArray());
            if (results.Count == 0)
            {
                throw new InvalidOperationException("No fake Azure CLI result remains.");
            }

            return Task.FromResult(results.Dequeue());
        }
    }
}
