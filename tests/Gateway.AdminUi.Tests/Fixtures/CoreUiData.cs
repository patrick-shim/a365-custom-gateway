using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Time.Testing;

namespace Gateway.AdminUi.Tests.Fixtures;

internal static class CoreUiData
{
    public static readonly DateTimeOffset Now = new(2030, 1, 2, 3, 4, 5, TimeSpan.Zero);
    public static readonly Guid AgentId = Guid.Parse("33333333-3333-4333-8333-333333333333");
    public static readonly Guid OperationId = Guid.Parse("44444444-4444-4444-8444-444444444444");
    public static readonly Guid BlueprintId = Guid.Parse("55555555-5555-4555-8555-555555555555");
    public static readonly Guid BlueprintClientId = Guid.Parse("66666666-6666-4666-8666-666666666666");
    public static readonly Guid KeyId = Guid.Parse("77777777-7777-4777-8777-777777777777");
    public static readonly Guid ReplacementId = Guid.Parse("88888888-8888-4888-8888-888888888888");
    public const string ExternalId = "core-fixture-agent";
    public const string Key = "synthetic-key-not-valid-for-any-service";
    public const string Version = "AAAAAAAAAAE=";

    public static AdminUiFixture Create(string role = "Gateway.Administrator")
    {
        var fixture = new AdminUiFixture(role);
        fixture.Services.RemoveAll<TimeProvider>();
        fixture.Services.AddSingleton<TimeProvider>(new FakeTimeProvider(Now));
        return fixture;
    }

    public static GatewayApiResource<T> Resource<T>(T value) => new(value, Version, "fixture-correlation");

    public static AgentFeaturesDto Features => new("Disabled", false, null, false, false, false);
    public static AgentGatewayCredentialDto Credential => new(KeyId, Key, Now.UtcDateTime.AddHours(1));
    public static AgentIngressCredentialMetadataDto Metadata(Guid? id = null, DateTime? expires = null, DateTime? revoked = null) =>
        new(id ?? KeyId, Now.UtcDateTime.AddDays(-1), expires ?? Now.UtcDateTime.AddHours(1), revoked);

    public static AgentDetailDto Agent(Guid? id = null, string status = "Active") => new(
        id ?? AgentId, ExternalId, "Core fixture agent", null, status, "Development",
        new Agent365InfoDto("fixture-child", BlueprintClientId.ToString("D"), "fixture-registry"),
        Features, null, Now.UtcDateTime.AddDays(-1), Now.UtcDateTime,
        AdminUiFixture.Actor.ToString("D"), null, AdminUiFixture.Actor.ToString("D"),
        AdminUiFixture.Actor.ToString("D"), Convert.FromBase64String(Version), null);

    public static AgentSummaryDto Summary(string externalId = ExternalId, Guid? id = null, string status = "Active") => new(
        id ?? AgentId, externalId, "Core fixture agent", null, status, "Development", null,
        Features, null, Now.UtcDateTime.AddDays(-1), Now.UtcDateTime);

    public static SystemConfigDto Config(bool agent365 = false, bool mirror = false, bool admission = true) => new(
        "ContinuousDevelopment", "Disabled", false, null, 7, 7, 7, 7, 10, 10, 100, false, 1, 1,
        true, false, agent365, mirror, admission, false, false, false, Version);

    public static AgentIdentityBlueprintListResponse Blueprints => new([
        new(BlueprintId, BlueprintClientId, "Shared fixture blueprint", true, null)
    ]);

    public static RegisterAgentResponse Registered(string externalId, string name = "Core fixture agent") => new(
        AgentId, externalId, name, "Provisioning", OperationId, Now.UtcDateTime, null, Credential);

    public static void ExpectProtection(AdminUiFixture fixture, bool details = false)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync), Resource(new ProtectionCapabilitiesResponse([])));
        if (details) fixture.Script.Return(nameof(IGatewayApiClient.GetSystemConfigAsync), Config());
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync), Resource(new PurviewDlpProfileListResponse([])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync), Resource(new PurviewTenantConnectionResponse(null)));
    }

    public static void ExpectRegistration(AdminUiFixture fixture, SystemConfigDto? config = null,
        AgentIdentityBlueprintListResponse? blueprints = null)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetSystemConfigAsync), config ?? Config());
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync), blueprints ?? Blueprints);
        ExpectProtection(fixture);
    }

    public static void ExpectSetup(AdminUiFixture fixture, bool administrator, int? count = 0)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetHealthAsync), new GatewayHealthStatus("Healthy"));
        fixture.Script.Return(nameof(IGatewayApiClient.GetReadinessAsync), new GatewayHealthStatus("Ready"));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([], null, count));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([], null, count));
        if (administrator) fixture.Script.Return(nameof(IGatewayApiClient.GetSystemConfigAsync), Config());
    }

    public static void ExpectDetails(AdminUiFixture fixture, string role,
        AgentDetailDto? agent = null, IReadOnlyList<AgentIngressCredentialMetadataDto>? keys = null, bool protection = true)
    {
        agent ??= Agent();
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentAsync), Resource(agent));
        if (role is "Gateway.Administrator" or "Gateway.Operator")
            fixture.Script.Return(nameof(IGatewayApiClient.GetProvisioningHistoryAsync), new ProvisioningHistoryResponse(agent.AgentId, []));
        if (role is "Gateway.Administrator" or "Gateway.Auditor")
            fixture.Script.Return(nameof(IGatewayApiClient.GetAgentAuditEventsAsync), new AuditEventListResponse([], null));
        if (role == "Gateway.Administrator")
        {
            fixture.Script.Return(nameof(IGatewayApiClient.GetAgentIngressCredentialsAsync),
                new AgentIngressCredentialListResponse(agent.AgentId, keys ?? [Metadata()]));
            if (protection) ExpectProtection(fixture, details: true);
        }
    }

    public static OperationStatusDto Operation(string status = "AwaitingAdministratorAction", bool available = true,
        bool polling = false, bool legacy = false, Guid? id = null) => new(
        id ?? OperationId, "Register", status, "RegisterAgent", 71, AgentId,
        Now.UtcDateTime, null, null, [], WorkflowVersion: 2, Legacy: legacy,
        ReplaySupported: false, PollingRecommended: polling,
        RequiredAction: status == "AwaitingAdministratorAction" ? "CompleteAgent365Registration" : null,
        Agent365RegistrationCompletionAvailable: available);

    public static GatewayApiException Error(System.Net.HttpStatusCode status, bool interaction = false,
        bool claims = false, bool validation = false) => new(
        status, "Fixture request rejected", "Synthetic fixture response.", null, null, "FIXTURE_ERROR",
        "fixture-correlation", validation ? new Dictionary<string, string[]> { ["Name"] = ["Choose another agent name."] } : new Dictionary<string, string[]>(),
        null, interaction, claims, interaction ? ["AgentRegistration.ReadWrite.All"] : null);
}
