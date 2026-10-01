using Gateway.Setup.Models;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Fixtures;

internal static class SetupFixtureValues
{
    public static readonly Guid SubscriptionId = Guid.Parse("11111111-1111-4111-8111-111111111111");
    public static readonly Guid TenantId = Guid.Parse("22222222-2222-4222-8222-222222222222");
    public static readonly Guid ManagerId = Guid.Parse("33333333-3333-4333-8333-333333333333");
    public static readonly Guid ManagerObjectId = Guid.Parse("44444444-4444-4444-8444-444444444444");
    public static readonly AzureSubscription Subscription = new(
        SubscriptionId, TenantId, "Offline fixture subscription", true, "Enabled");
    public static readonly AzureLocation Location = new("koreacentral", "Korea Central");
    public const string Fingerprint = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    public const string PlanResult = """
        {"schemaVersion":1,"timestampUtc":"2026-09-16T00:00:00Z","type":"Result","message":"Plan is ready for explicit acceptance.","data":{"step":"Plan review","category":"planResult","index":1,"total":19,"planFingerprint":"sha256:1111111111111111111111111111111111111111111111111111111111111111","applyReady":true}}
        """;

    public static void MakeReady(SetupWizardState state)
    {
        state.AcceptWelcome();
        state.SetSubscriptions([Subscription]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(SubscriptionId, [Location], null));
        if (!state.SelectLocation(Location.Name))
        {
            throw new InvalidOperationException("The fixture region must be selected explicitly.");
        }

        state.ApplyManagerApplicationDiscovery(new ManagerApplicationDiscoveryResult(
            SubscriptionId,
            TenantId,
            [new ManagerApplicationCandidate(
                ManagerId, ManagerObjectId, "Offline fixture manager", "Fixture publisher",
                "Fixture publisher", "Application", 1, ["Offline fixture blueprint"])],
            "Synthetic fixture inventory; never read from a provider",
            null));
        if (!state.AcceptDiscoveredManagerApplications())
        {
            throw new InvalidOperationException("The fixture manager set must be accepted explicitly.");
        }

        state.Form.AlertEmail = "operator@example.test";
        state.Form.RegistryBetaAcknowledged = true;
        state.Form.PromptShieldCostAndQuotaAcknowledged = true;
        state.Form.PurviewAuthorityRequirementsAcknowledged = true;
    }
}

internal sealed class FixtureProjectNameGenerator : IProjectNameGenerator
{
    public string Create() => "gwtest1";
}

internal sealed class SetupFixtureDirectory : IDisposable
{
    public string RootPath { get; } = Path.Combine(
        AppContext.BaseDirectory, $"gateway-setup-fixture-{Guid.NewGuid():N}");

    public SetupFixtureDirectory()
    {
        Directory.CreateDirectory(Path.Combine(RootPath, "bootstrap"));
        Directory.CreateDirectory(Path.Combine(RootPath, "src"));
        File.WriteAllText(
            Path.Combine(RootPath, "bootstrap", "bootstrap.ps1"),
            "throw 'Offline fixture: no bootstrap process may run.'");
        File.WriteAllText(Path.Combine(RootPath, "src", "A365Gateway.slnx"), "<Solution />");
    }

    public void Dispose()
    {
        if (Directory.Exists(RootPath))
        {
            Directory.Delete(RootPath, recursive: true);
        }
    }
}
