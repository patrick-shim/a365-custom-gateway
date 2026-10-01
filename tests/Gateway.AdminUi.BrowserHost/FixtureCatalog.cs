using Gateway.AdminUi.Services;

namespace Gateway.AdminUi.BrowserHost;

internal sealed record FixtureScenario(
    string Name,
    string Description,
    int AgentCount = 0,
    string Blueprints = "compatible",
    string Registration = "success",
    string Completion = "success",
    string OperationStatus = "Completed",
    bool CompletionAvailable = true,
    bool Admission = true,
    bool TelemetryDefaults = false,
    bool UnknownTotal = false,
    bool Legacy = false,
    string Credential = "success",
    string Lifecycle = "success",
    bool ExpiredCredentials = false,
    string[]? ReadErrors = null,
    bool RejectCursorReads = false,
    string Protection = "none");

internal sealed record FixtureResetRequest(
    string Scenario = "fleet",
    string Role = "Administrator",
    int MutationDelayMs = 250);

internal sealed record FixtureOperationRequest(
    string Status,
    Guid? OperationId = null,
    string? Completion = null,
    bool? Available = null);

internal sealed record FixtureReadErrorsRequest(string[] Methods);

internal static class FixtureCatalog
{
    public const int FleetTotal = 237;
    public const int FilteredFleetTotal = 137;

    public static readonly string[] CompletionOutcomes =
        ["success", "verifying", "consent", "claims", "unknown", "unknown-committed", "rejected"];
    public static readonly string[] OperationStatuses =
        ["Pending", "Running", "AwaitingAdministratorAction", "RequiresManualIntervention", "Completed", "Failed", "Cancelled"];

    public static readonly string[] ReadMethods =
    [
        nameof(IGatewayApiClient.GetHealthAsync),
        nameof(IGatewayApiClient.GetReadinessAsync),
        nameof(IGatewayApiClient.GetAgentsAsync),
        nameof(IGatewayApiClient.GetAgentAsync),
        nameof(IGatewayApiClient.GetAgentIngressCredentialsAsync),
        nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync),
        nameof(IGatewayApiClient.GetPurviewPolicyProfilesAsync),
        nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync),
        nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
        nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
        nameof(IGatewayApiClient.GetPurviewKnowYourDataAsync),
        nameof(IGatewayApiClient.GetAgentAuditEventsAsync),
        nameof(IGatewayApiClient.GetProvisioningHistoryAsync),
        nameof(IGatewayApiClient.GetOperationStatusAsync),
        nameof(IGatewayApiClient.GetSystemConfigAsync),
        nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync),
        nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
        nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync)
    ];

    private static readonly FixtureScenario[] Scenarios =
    [
        new("empty", "New installation; no registered agents, core-only defaults."),
        new("fleet", "237 agents, tied timestamps and 137 Active/Development/invoice-eu matches; exact filtered totals.", AgentCount: FleetTotal),
        new("unknown-total", "The same 237-agent fleet and working cursors, but the API deliberately omits TotalCount.", AgentCount: FleetTotal, UnknownTotal: true),
        new("cursor-error", "First-page reads work; continuation reads return HTTP 400 with a Cursor validation error. Restart keeps the filters.", AgentCount: FleetTotal, RejectCursorReads: true),
        new("defaults", "Registration defaults enable both telemetry destinations; optional protection stays off.", TelemetryDefaults: true),
        new("admission-closed", "Registration admission is closed.", Admission: false),
        new("blueprints-empty", "Blueprint read succeeds with no compatible or rejected items.", Blueprints: "empty"),
        new("blueprints-rejected", "Only an incompatible blueprint is returned.", Blueprints: "rejected"),
        new("blueprints-mixed", "A compatible and an incompatible blueprint are returned.", Blueprints: "mixed"),
        new("blueprints-error", "Blueprint inventory read fails until /read-errors clears it.",
            ReadErrors: [nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync)]),
        new("registration-validation", "Registration returns field validation errors without creating anything.", Registration: "validation"),
        new("registration-unknown", "Registration is persisted but its response is interrupted; external-ID readback finds it.", Registration: "unknown"),
        new("registration-no-key", "Accepted registration omits its one-time key; recover on existing-agent details.", Registration: "no-key"),
        new("operation-manual", "Existing delegated Registry operation; direct entry has no automatic-completion permit.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction"),
        new("operation-auto", "Register from an empty inventory, save the one-time key, then test the production automatic handoff."),
        new("operation-pending", "An existing running operation; advance explicitly with /operation.",
            AgentCount: 1, OperationStatus: "Running"),
        new("operation-verifying", "Registry completion is accepted but final verification remains Running until /operation advances it.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", Completion: "verifying"),
        new("operation-unavailable", "Delegated completion is not advertised by the server.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", CompletionAvailable: false),
        new("operation-consent", "Delegated completion returns an administrator consent challenge without starting authentication.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", Completion: "consent"),
        new("operation-claims", "Delegated completion returns a claims challenge without starting authentication.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", Completion: "claims"),
        new("operation-unknown", "Registry response is interrupted and readback remains manual intervention; never repeat the mutation.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", Completion: "unknown"),
        new("operation-unknown-committed", "Registry completion is persisted before its response is interrupted; readback confirms completion.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", Completion: "unknown-committed"),
        new("operation-failed", "A failed, current-version operation with safe error metadata.", AgentCount: 1, OperationStatus: "Failed"),
        new("operation-legacy", "Historical read-only operation; no automatic polling or replay.",
            AgentCount: 1, OperationStatus: "AwaitingAdministratorAction", Legacy: true, CompletionAvailable: false),
        new("read-error", "Inventory, agent and operation reads fail; clear /read-errors to test recovery.", AgentCount: FleetTotal,
            ReadErrors: [nameof(IGatewayApiClient.GetAgentsAsync), nameof(IGatewayApiClient.GetAgentAsync), nameof(IGatewayApiClient.GetOperationStatusAsync)]),
        new("readiness-error", "Database readiness read fails; the other setup checks still return data.",
            ReadErrors: [nameof(IGatewayApiClient.GetReadinessAsync)]),
        new("credential-expired", "An Active agent has an expired old credential; issue a replacement.", AgentCount: 1, ExpiredCredentials: true),
        new("credential-unknown", "Replacement metadata persists before the one-time response is interrupted.", AgentCount: 1, Credential: "issue-unknown"),
        new("revocation-unknown", "Revocation persists before the response is interrupted; issue a second key first.", AgentCount: 1, Credential: "revoke-unknown"),
        new("lifecycle-unknown", "Enable/disable persists before its response is interrupted; read back current state.", AgentCount: 1, Lifecycle: "unknown"),
        new("m4-core", "Core-only optional capabilities are not installed.", AgentCount: 1, Protection: "core"),
        new("m4-connection", "Review a new tenant connection and independently advance its verification.", AgentCount: 1, Protection: "connection"),
        new("m4-connection-pending", "Reopen an accepted actor-bound companion launch.", AgentCount: 1, Protection: "connection-pending"),
        new("m4-connection-expired", "Review a new authorization after a known companion launch expires.", AgentCount: 1, Protection: "connection-expired"),
        new("m4-connection-unknown", "Connection start persists then loses its response.", AgentCount: 1, Protection: "connection-unknown"),
        new("m4-ready", "Current certified shared Enforce profile, two synthetic classifiers.", AgentCount: 1, Protection: "ready"),
        new("m4-simulation", "Verified non-enforcing simulation with policy tips.", AgentCount: 1, Protection: "simulation"),
        new("m4-off", "Saved shared policy Off, independently enabled Prompt Shields.", AgentCount: 1, Protection: "off"),
        new("m4-expired", "Historical Enforce evidence is expired.", AgentCount: 1, Protection: "expired"),
        new("m4-inventory-stale", "Expired classifier inventory preserves selections but blocks review.", AgentCount: 1, Protection: "inventory-stale"),
        new("m4-inventory-wrong", "A mismatched inventory tenant cannot authorize.", AgentCount: 1, Protection: "inventory-wrong"),
        new("m4-policy-conflict", "A policy change invalidates its reviewed version at confirmation.", AgentCount: 1, Protection: "policy-conflict"),
        new("m4-policy-unknown", "A policy start persists before losing the response.", AgentCount: 1, Protection: "policy-unknown"),
        new("m4-runtime-unknown", "Runtime outcome is unknown and cannot certify protection.", AgentCount: 1, Protection: "runtime-unknown"),
        new("m4-runtime-expiry", "Replacement runtime readiness expires before the original profile snapshot.", AgentCount: 1, Protection: "runtime-expiry"),
        new("m4-runtime-unknown-committed", "Runtime result persists before its response is lost; recovery is GET only.", AgentCount: 1, Protection: "runtime-unknown-committed")
    ];

    public static FixtureScenario Get(string name) =>
        Scenarios.SingleOrDefault(item => item.Name == name)
        ?? throw new ArgumentException("Unknown fixture scenario. GET /__fixture/catalog lists the finite catalog.");

    public static object Contract() => new
    {
        roles = FixtureIdentity.Roles,
        scenarios = Scenarios.Select(item => new { item.Name, item.Description }),
        operationStatuses = OperationStatuses,
        completionOutcomes = CompletionOutcomes,
        readMethods = ReadMethods,
        resetRequiresFreshDocument = true,
        fleet = new
        {
            total = FleetTotal,
            filter = new { status = "Active", environment = "Development", search = "invoice-eu", total = FilteredFleetTotal },
            fullFinalPageFilter = new { search = "Auxiliary", total = 100 },
            nameOnlyAgentId = FixtureState.SeedAgentId(1),
            externalIdOnlyAgentId = FixtureState.SeedAgentId(2),
            registeredCount = FleetTotal,
            activeCount = 177,
            actionRequiredCount = 30,
            order = "CreatedAtUtc ascending, then SQL Server GUID ascending",
            cursor = "Unmodified production ListAgentsCursor source; versioned 34-character base64url"
        },
        mutationCounterNames = new[]
        {
            nameof(IGatewayApiClient.RegisterAgentAsync),
            nameof(IGatewayApiClient.IssueAgentIngressCredentialAsync),
            nameof(IGatewayApiClient.RevokeAgentIngressCredentialAsync),
            nameof(IGatewayApiClient.EnableAgentAsync),
            nameof(IGatewayApiClient.DisableAgentAsync),
            nameof(IGatewayApiClient.DeleteAgentAsync),
            nameof(IGatewayApiClient.RetryProvisioningAsync),
            nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync)
        }
    };
}
