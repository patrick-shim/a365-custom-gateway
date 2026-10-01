using System.Data.SqlTypes;
using System.Net;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.BrowserHost;

internal sealed record FixtureLease(int Generation, string Role);
internal enum FixtureAccess { All, Administrator, Operations, Audit }
internal sealed record FixtureCall(int Sequence, string Method, string Role, Guid? TargetId, bool Mutation, string Outcome);

internal sealed partial class FixtureState
{
    internal static readonly Guid BlueprintId = Guid.Parse("55555555-5555-4555-8555-555555555555");
    internal static readonly Guid BlueprintClientId = Guid.Parse("66666666-6666-4666-8666-666666666666");
    internal static readonly Guid RejectedBlueprintId = Guid.Parse("55555555-5555-4555-8555-555555555556");
    internal const string Version = "AAAAAAAAAAE=";
    private static readonly IComparer<Guid> SqlGuidOrder = Comparer<Guid>.Create(
        (left, right) => new SqlGuid(left).CompareTo(new SqlGuid(right)));
    private readonly object sync = new();
    private readonly Dictionary<Guid, AgentDetailDto> agents = [];
    private readonly Dictionary<Guid, List<AgentIngressCredentialMetadataDto>> credentials = [];
    private readonly Dictionary<Guid, OperationStatusDto> operations = [];
    private readonly Dictionary<Guid, List<AuditEventDto>> audit = [];
    private readonly Dictionary<string, int> counters = new(StringComparer.Ordinal);
    private readonly List<FixtureCall> calls = [];
    private readonly List<string> unexpectedCalls = [];
    private HashSet<string> readErrors = new(StringComparer.Ordinal);
    private FixtureScenario scenario = FixtureCatalog.Get("fleet");
    private string role = GatewayRoles.Administrator;
    private string completion = "success";
    private DateTime now;
    private int generation;
    private int mutationDelayMs;
    private int nextAgent;
    private int nextOperation;
    private int nextKey;
    private int nextEvent;
    private int staleLeaseCalls;
    private Guid? newestOperationId;
    private object? lastRegistration;

    public FixtureState(BrowserHostOptions options) =>
        Reset(new(options.Scenario, options.Role, options.MutationDelayMs));

    public int Generation { get { lock (sync) return generation; } }
    public string Role { get { lock (sync) return role; } }
    public FixtureLease CaptureLease() { lock (sync) return new(generation, role); }

    public object Reset(FixtureResetRequest request)
    {
        var selected = FixtureCatalog.Get(request.Scenario);
        var selectedRole = FixtureIdentity.NormalizeRole(request.Role);
        if (request.MutationDelayMs is < 0 or > 5000)
            throw new ArgumentException("mutationDelayMs must be between 0 and 5000.");
        lock (sync)
        {
            generation++;
            scenario = selected;
            role = selectedRole;
            completion = selected.Completion;
            mutationDelayMs = request.MutationDelayMs;
            now = DateTime.UtcNow;
            agents.Clear();
            credentials.Clear();
            operations.Clear();
            audit.Clear();
            counters.Clear();
            calls.Clear();
            unexpectedCalls.Clear();
            readErrors = new(selected.ReadErrors ?? [], StringComparer.Ordinal);
            nextAgent = nextOperation = nextKey = nextEvent = staleLeaseCalls = 0;
            newestOperationId = null;
            lastRegistration = null;
            for (var index = 1; index <= selected.AgentCount; index++)
                SeedAgent(selected.AgentCount == FixtureCatalog.FleetTotal
                    ? index switch { 2 => 3, 3 => 2, _ => index }
                    : index);
            InitializeProtection();
            return SnapshotCore();
        }
    }

    public object Snapshot() { lock (sync) return SnapshotCore(); }

    private object SnapshotCore() => new
    {
        generation,
        scenario = scenario.Name,
        role = role[8..],
        mutationDelayMs,
        agentCount = agents.Values.Count(item => item.Status != "Deleted"),
        statusCounts = agents.Values.Where(item => item.Status != "Deleted").GroupBy(item => item.Status)
            .ToDictionary(group => group.Key, group => group.Count()),
        primaryAgentId = agents.Keys.FirstOrDefault(),
        primaryOperationId = operations.Keys.FirstOrDefault(),
        newestOperationId,
        blueprintId = BlueprintId,
        rejectedBlueprintId = RejectedBlueprintId,
        tenantId = FixtureIdentity.TenantId,
        actorId = FixtureIdentity.ActorId,
        lastRegistration,
        protection = ProtectionSnapshot(),
        counters = new Dictionary<string, int>(counters, StringComparer.Ordinal),
        calls = calls.TakeLast(200).ToArray(),
        unexpectedCalls = unexpectedCalls.ToArray(),
        staleLeaseCalls,
        readErrors = readErrors.Order(StringComparer.Ordinal).ToArray(),
        agents = agents.Values.Select(item => new
        {
            item.AgentId, item.ExternalAgentId, item.Status,
            keys = credentials[item.AgentId].Select(key => new { key.KeyId, key.ExpiresAtUtc, key.RevokedAtUtc })
        }).ToArray(),
        operations = operations.Values.Select(item => new
        {
            item.OperationId, item.AgentId, item.Type, item.Status, item.CurrentStep,
            item.Agent365RegistrationCompletionAvailable, item.PollingRecommended
        }).ToArray()
    };

    public object SetReadErrors(FixtureReadErrorsRequest request)
    {
        if (request.Methods is null || request.Methods.Length > FixtureCatalog.ReadMethods.Length ||
            request.Methods.Any(method => !FixtureCatalog.ReadMethods.Contains(method, StringComparer.Ordinal)))
            throw new ArgumentException("methods must contain only supported read names from /__fixture/catalog.");
        lock (sync)
        {
            readErrors = new(request.Methods, StringComparer.Ordinal);
            return SnapshotCore();
        }
    }

    public object SetOperation(FixtureOperationRequest request)
    {
        if (!FixtureCatalog.OperationStatuses.Contains(request.Status, StringComparer.Ordinal) ||
            request.Completion is not null && !FixtureCatalog.CompletionOutcomes.Contains(request.Completion, StringComparer.Ordinal))
            throw new ArgumentException("Choose a status and completion outcome from /__fixture/catalog.");
        lock (sync)
        {
            if ((request.OperationId ?? newestOperationId) is not { } id || !operations.TryGetValue(id, out var operation))
                throw new ArgumentException("No matching synthetic operation exists.");
            if (request.Completion is not null) completion = request.Completion;
            operations[id] = Transition(operation, request.Status, request.Available ?? scenario.CompletionAvailable);
            return SnapshotCore();
        }
    }

    public UnexpectedFixtureCallException RejectUnexpected(string method)
    {
        lock (sync)
        {
            if (unexpectedCalls.Count < 100) unexpectedCalls.Add(method);
            counters[method] = counters.GetValueOrDefault(method) + 1;
        }
        Console.Error.WriteLine($"BROWSER_FIXTURE_UNEXPECTED_API {method}");
        return new($"Unscripted browser fixture API method '{method}'; no HTTP fallback exists.");
    }

    public async Task<T> ExecuteAsync<T>(
        FixtureLease lease, string method, FixtureAccess access, Guid? targetId,
        bool mutation, CancellationToken cancellationToken, Func<T> respond)
    {
        int sequence;
        int delay;
        lock (sync)
        {
            CheckLease(lease);
            if (calls.Count >= 10000)
                throw RejectUnexpected("FixtureCallBudgetExceeded");
            sequence = calls.Count + 1;
            calls.Add(new(sequence, method, lease.Role[8..], targetId, mutation, "pending"));
            counters[method] = counters.GetValueOrDefault(method) + 1;
            delay = mutation ? mutationDelayMs : 0;
        }
        try
        {
            if (!Permitted(lease.Role, access))
                throw Error(HttpStatusCode.Forbidden, "The synthetic role cannot call this API method.", "FORBIDDEN");
            cancellationToken.ThrowIfCancellationRequested();
            if (delay > 0) await Task.Delay(delay, cancellationToken);
            lock (sync)
            {
                CheckLease(lease);
                cancellationToken.ThrowIfCancellationRequested();
                if (readErrors.Contains(method))
                    throw Error(HttpStatusCode.ServiceUnavailable, "This read is unavailable in the selected browser fixture.", "FIXTURE_READ_ERROR");
                var result = respond();
                calls[sequence - 1] = calls[sequence - 1] with { Outcome = "returned" };
                return result;
            }
        }
        catch (Exception exception)
        {
            lock (sync)
            {
                if (generation == lease.Generation)
                    calls[sequence - 1] = calls[sequence - 1] with
                    {
                        Outcome = exception switch
                        {
                            GatewayApiTransportException => "unknown",
                            GatewayApiException api => $"rejected:{(int)api.StatusCode}",
                            OperationCanceledException => "cancelled",
                            _ => "fixture-error"
                        }
                    };
            }
            throw;
        }
    }

    private void CheckLease(FixtureLease lease)
    {
        if (lease.Generation == generation && lease.Role == role) return;
        staleLeaseCalls++;
        throw new UnexpectedFixtureCallException("An old browser circuit cannot access a reset fixture. Open a fresh document.");
    }

    private static bool Permitted(string selectedRole, FixtureAccess access) => access switch
    {
        FixtureAccess.All => true,
        FixtureAccess.Administrator => selectedRole == GatewayRoles.Administrator,
        FixtureAccess.Operations => selectedRole is GatewayRoles.Administrator or GatewayRoles.Operator,
        FixtureAccess.Audit => selectedRole is GatewayRoles.Administrator or GatewayRoles.Auditor,
        _ => false
    };

    // Responders run under the state lock after a generation/role check. They never
    // invoke providers and only return contract DTOs or explicitly scripted failures.
    internal AgentListResponse GetAgents(AgentListQuery? query)
    {
        query ??= new();
        if (query.Limit is < 1 or > 100)
            throw Error(HttpStatusCode.BadRequest, "Page limit must be from 1 through 100.", "INVALID_LIMIT");
        var filtered = agents.Values.Where(item => item.Status != "Deleted")
            .Where(item => string.IsNullOrWhiteSpace(query.Status) || item.Status.Equals(query.Status.Trim(), StringComparison.OrdinalIgnoreCase))
            .Where(item => string.IsNullOrWhiteSpace(query.Environment) || item.Environment.Equals(query.Environment.Trim(), StringComparison.OrdinalIgnoreCase))
            .Where(item => string.IsNullOrWhiteSpace(query.Search) ||
                item.Name.Contains(query.Search.Trim(), StringComparison.OrdinalIgnoreCase) ||
                item.ExternalAgentId.Contains(query.Search.Trim(), StringComparison.OrdinalIgnoreCase))
            .OrderBy(item => item.CreatedAtUtc).ThenBy(item => item.AgentId, SqlGuidOrder).ToArray();
        var page = filtered.AsEnumerable();
        if (query.Cursor is not null)
        {
            if (scenario.RejectCursorReads ||
                !ListAgentsCursor.TryDecode(query.Cursor, out var createdAt, out var agentId))
                throw InvalidCursor();
            page = page.Where(item => item.CreatedAtUtc > createdAt ||
                item.CreatedAtUtc == createdAt && SqlGuidOrder.Compare(item.AgentId, agentId) > 0);
        }
        var candidates = page.Take(query.Limit + 1).ToArray();
        var items = candidates.Take(query.Limit).Select(Summary).ToList();
        var last = items.LastOrDefault();
        var next = candidates.Length > query.Limit && last is not null
            ? ListAgentsCursor.Encode(last.CreatedAtUtc, last.AgentId)
            : null;
        return new(items, next, scenario.UnknownTotal ? null : filtered.Length);
    }

    private static GatewayApiException InvalidCursor() => Error(
        HttpStatusCode.BadRequest, ListAgentsCursor.InvalidMessage, "INVALID_CURSOR",
        new Dictionary<string, string[]> { ["Cursor"] = [ListAgentsCursor.InvalidMessage] });

    internal GatewayApiResource<AgentDetailDto> GetAgent(Guid id) => Resource(FindAgent(id));
    internal AgentIngressCredentialListResponse GetCredentials(Guid id) => new(FindAgent(id).AgentId, credentials[id].ToArray());
    internal SystemConfigDto GetConfig() => new(
        "ContinuousDevelopment", scenario.TelemetryDefaults ? "Agent365AzureMonitor" : "Disabled",
        false, null, 7, 7, 7, 7, 10, 10, 100, false, 1, 1, true, false,
        scenario.TelemetryDefaults, scenario.TelemetryDefaults, scenario.Admission, ProtectionInstalled, false, ProtectionInstalled, Version);

    internal AgentIdentityBlueprintListResponse GetBlueprints()
    {
        var items = new List<AgentIdentityBlueprintSummaryDto>();
        if (scenario.Blueprints is "compatible" or "mixed")
            items.Add(new(BlueprintId, BlueprintClientId, "Compatible synthetic blueprint", true, null));
        if (scenario.Blueprints is "rejected" or "mixed")
            items.Add(new(RejectedBlueprintId, Guid.Parse("66666666-6666-4666-8666-666666666667"),
                "Rejected synthetic blueprint", false, "Missing the required Agent 365 application permission."));
        return new(items);
    }

    internal RegisterAgentResponse Register(RegisterAgentRequest request)
    {
        if (!scenario.Admission)
            throw Error(HttpStatusCode.Conflict, "Synthetic registration admission is closed.", "PROVISIONING_NOT_ENABLED");
        if (scenario.Registration == "validation")
            throw Error(HttpStatusCode.BadRequest, "Choose another agent name.", "VALIDATION_ERROR",
                new Dictionary<string, string[]> { ["Name"] = ["This synthetic scenario rejects the submitted name."] });
        if (string.IsNullOrWhiteSpace(request.ExternalAgentId) || request.ExternalAgentId.Length > 128 ||
            string.IsNullOrWhiteSpace(request.Name) || request.Name.Length > 200 ||
            !Guid.TryParse(request.OwnerObjectId, out var owner) || owner != FixtureIdentity.ActorId)
            throw Error(HttpStatusCode.BadRequest, "A synthetic external ID, name and fixture owner are required.", "VALIDATION_ERROR");
        if (agents.Values.Any(item => item.ExternalAgentId.Equals(request.ExternalAgentId, StringComparison.OrdinalIgnoreCase)))
            throw Error(HttpStatusCode.Conflict, "The external ID already has a registration.", "AGENT_ALREADY_EXISTS");
        if (request.Blueprint is { Mode: "UseExisting" } blueprint &&
            (!Guid.TryParse(blueprint.BlueprintObjectId, out var id) ||
             !GetBlueprints().Items.Any(item => item.BlueprintObjectId == id && item.IsAgent365Compatible)))
            throw Error(HttpStatusCode.BadRequest, "Select a currently compatible blueprint.", "INVALID_BLUEPRINT",
                new Dictionary<string, string[]> { ["Blueprint.BlueprintObjectId"] = ["This blueprint is not compatible."] });
        if (request.Blueprint is { Mode: not ("CreateNew" or "UseExisting") })
            throw Error(HttpStatusCode.BadRequest, "Unknown blueprint selection mode.", "INVALID_BLUEPRINT");
        if (request.Features is { PurviewEnabled: true } or { PromptShieldEnabled: true } ||
            request.PurviewConfigurationIntent is not null)
            throw RejectUnexpected("RegisterAgentAsync.ProtectionMutation");

        var agentId = Id(3, ++nextAgent);
        var features = request.Features ?? Features(scenario.TelemetryDefaults);
        var agent = NewAgent(agentId, request.ExternalAgentId, request.Name, "AwaitingAdminApproval",
            request.Environment, now, features) with { Description = request.Description };
        agents.Add(agentId, agent);
        credentials.Add(agentId, []);
        audit.Add(agentId, []);
        var operation = NewOperation(agentId, "Register", "AwaitingAdministratorAction");
        var key = IssueKey(agentId);
        AddAudit(agentId, "AgentRegistered");
        lastRegistration = new
        {
            agent.AgentId, agent.ExternalAgentId, operation.OperationId,
            blueprintMode = request.Blueprint?.Mode,
            blueprintObjectId = request.Blueprint?.BlueprintObjectId,
            features.Agent365ObservabilityEnabled, features.AzureMonitorExportEnabled,
            features.PurviewEnabled, features.PromptShieldEnabled
        };
        if (scenario.Registration == "unknown") throw Interrupted();
        return new(agentId, agent.ExternalAgentId, agent.Name, "Provisioning", operation.OperationId, now, null,
            scenario.Registration == "no-key" ? null : key);
    }

    internal IssueAgentIngressCredentialResponse IssueCredential(Guid id)
    {
        var agent = FindAgent(id);
        if (agent.Status is "Deleting" or "Deleted")
            throw Error(HttpStatusCode.Conflict, "Cannot issue a credential during deletion.", "INVALID_STATE");
        var key = IssueKey(id);
        AddAudit(id, "AgentIngressCredentialIssued");
        if (scenario.Credential == "issue-unknown") throw Interrupted();
        return new(id, agent.ExternalAgentId, key);
    }

    internal RevokeAgentIngressCredentialResponse RevokeCredential(Guid id, Guid keyId)
    {
        FindAgent(id);
        var metadata = credentials[id].SingleOrDefault(item => item.KeyId == keyId)
            ?? throw Error(HttpStatusCode.NotFound, "No such synthetic credential.", "CREDENTIAL_NOT_FOUND");
        if (metadata.RevokedAtUtc is not null) return new(id, metadata, true);
        if (metadata.ExpiresAtUtc > DateTime.UtcNow &&
            !credentials[id].Any(item => item.KeyId != keyId && item.RevokedAtUtc is null && item.ExpiresAtUtc > DateTime.UtcNow))
            throw Error(HttpStatusCode.Conflict, "Issue and save a replacement before revoking the last usable key.", "LAST_USABLE_CREDENTIAL");
        var revoked = metadata with { RevokedAtUtc = DateTime.UtcNow };
        credentials[id][credentials[id].IndexOf(metadata)] = revoked;
        AddAudit(id, "AgentIngressCredentialRevoked");
        if (scenario.Credential == "revoke-unknown") throw Interrupted();
        return new(id, revoked, false);
    }

    internal AgentStateChangeResponse ChangeAgentState(Guid id, bool enabled)
    {
        var agent = FindAgent(id);
        if (agent.Status != (enabled ? "Disabled" : "Active"))
            throw Error(HttpStatusCode.Conflict, "The synthetic agent state does not allow that action.", "INVALID_STATE");
        var status = enabled ? "Active" : "Disabled";
        agents[id] = agent with { Status = status, UpdatedAtUtc = DateTime.UtcNow };
        AddAudit(id, enabled ? "AgentEnabled" : "AgentDisabled");
        if (scenario.Lifecycle == "unknown") throw Interrupted();
        return new(id, status, agents[id].UpdatedAtUtc);
    }

    internal DeleteAgentResponse Delete(Guid id)
    {
        var agent = FindAgent(id);
        if (agent.Status is "Deleting" or "Deleted")
            throw Error(HttpStatusCode.Conflict, "Deletion is already in progress.", "INVALID_STATE");
        agents[id] = agent with { Status = "Deleting", UpdatedAtUtc = DateTime.UtcNow };
        var operation = NewOperation(id, "Delete", "Running");
        AddAudit(id, "AgentDeletionRequested");
        return new(id, "Deleting", operation.OperationId, null);
    }

    internal AsyncOperationResponse Retry(Guid id)
    {
        var agent = FindAgent(id);
        if (agent.Status != "Failed" || agent.RetryProvisioning?.Supported != true)
            throw Error(HttpStatusCode.Conflict, "This operation cannot be replayed.", "RETRY_NOT_SUPPORTED");
        agents[id] = agent with { Status = "Provisioning", UpdatedAtUtc = DateTime.UtcNow };
        var operation = NewOperation(id, "Register", "Running");
        AddAudit(id, "ProvisioningRetried");
        return new(id, "Provisioning", operation.OperationId, null);
    }

    internal AuditEventListResponse GetAudit(Guid id, AuditEventQuery? query)
    {
        FindAgent(id);
        query ??= new();
        if (query.Limit is < 1 or > 100 || query.Cursor is not null)
            throw Error(HttpStatusCode.BadRequest, "This bounded audit fixture has one page only.", "INVALID_QUERY");
        return new(audit[id].OrderByDescending(item => item.OccurredAtUtc).Take(query.Limit).ToList(), null);
    }

    internal ProvisioningHistoryResponse GetHistory(Guid id)
    {
        FindAgent(id);
        return new(id, operations.Values.Where(item => item.AgentId == id)
            .OrderByDescending(item => item.StartedAtUtc).Select(item => new ProvisioningJobDto(
                item.OperationId, item.Type, item.Status, item.PercentComplete, item.StartedAtUtc,
                item.CompletedAtUtc, item.Error, item.Steps?.ToList())).ToList());
    }

    internal OperationStatusDto GetOperation(Guid id) =>
        operations.TryGetValue(id, out var operation)
            ? operation with { Steps = operation.Steps?.ToList() }
            : throw Error(HttpStatusCode.NotFound, "No such synthetic operation.", "OPERATION_NOT_FOUND");

    internal CompleteAgent365RegistrationResponse Complete(Guid id)
    {
        var operation = GetOperation(id);
        if (operation.Legacy || operation.Type != "Register" ||
            !operation.Agent365RegistrationCompletionAvailable ||
            operation.Status != "AwaitingAdministratorAction")
            throw Error(HttpStatusCode.Conflict, "Delegated completion is not currently available.", "COMPLETION_UNAVAILABLE");
        if (completion is "consent" or "claims")
            throw new GatewayApiException(HttpStatusCode.Unauthorized, "Synthetic delegated action requires interaction",
                "Use the existing operation after resolving the simulated challenge.", null, null,
                completion == "claims" ? "CLAIMS_CHALLENGE" : "CONSENT_REQUIRED",
                "browser-fixture-correlation", new Dictionary<string, string[]>(), null, true, completion == "claims",
                ["AgentRegistration.ReadWrite.All"]);
        if (completion == "rejected")
            throw Error(HttpStatusCode.Forbidden, "The synthetic delegated action was rejected.", "FORBIDDEN");
        var status = completion switch
        {
            "verifying" => "Running",
            "unknown" => "RequiresManualIntervention",
            _ => "Completed"
        };
        operations[id] = Transition(operation, status, false, registryAccepted: completion != "unknown");
        AddAudit(operation.AgentId, "Agent365CompletionRequested");
        if (completion is "unknown" or "unknown-committed") throw Interrupted();
        return new(id, operation.AgentId, $"synthetic-registry-{operation.AgentId:D}", operations[id].Status);
    }

    private void SeedAgent(int index)
    {
        var fleet = scenario.AgentCount == FixtureCatalog.FleetTotal;
        var status = fleet ? index switch
        {
            <= 157 => "Active",
            <= 177 => "Disabled",
            <= 197 => "Active",
            <= 207 => "AwaitingAdminApproval",
            <= 217 => "Failed",
            <= 227 => "RequiresManualIntervention",
            <= 232 => "Provisioning",
            _ => "Draft"
        } : AgentStatus(scenario.OperationStatus);
        var environment = !fleet || index <= 137 || index is >= 158 and <= 197
            ? "Development" : index <= 157 ? "Test" : "Production";
        var name = $"Synthetic agent {index:D3}";
        var externalId = $"fixture-agent-{index:D3}";
        if (fleet)
        {
            if (index <= FixtureCatalog.FilteredFleetTotal)
            {
                if (index % 2 == 0) externalId = $"invoice-eu-{index:D3}";
                else name += " invoice-eu";
            }
            else
            {
                name = $"Auxiliary {name}";
                if (index is < 178 or > 197) name += " invoice-eu";
            }
        }
        nextAgent++;
        var id = fleet ? SeedAgentId(index) : Id(3, nextAgent);
        var createdAt = fleet ? now.AddMinutes(-1000 + (index - 1) / 3) : now.AddMinutes(-index);
        agents[id] = NewAgent(id, externalId, name, status, environment, createdAt, Features());
        credentials[id] = [];
        audit[id] = [];
        IssueKey(id);
        if (scenario.ExpiredCredentials)
            credentials[id][0] = credentials[id][0] with { ExpiresAtUtc = now.AddMinutes(-1) };
        var operationStatus = scenario.AgentCount == 1 ? scenario.OperationStatus : status switch
        {
            "Active" or "Disabled" => "Completed",
            "AwaitingAdminApproval" => "AwaitingAdministratorAction",
            "Failed" => "Failed",
            "RequiresManualIntervention" => "RequiresManualIntervention",
            _ => "Running"
        };
        NewOperation(id, "Register", operationStatus);
        AddAudit(id, "AgentRegistered");
    }

    private AgentDetailDto NewAgent(Guid id, string externalId, string name, string status,
        string environment, DateTime createdAt, AgentFeaturesDto features) => new(
        id, externalId, name, "Synthetic browser fixture; no Microsoft resource exists.", status, environment,
        new Agent365InfoDto($"synthetic-child-{id:D}", BlueprintClientId.ToString("D"),
            status is "Active" or "Disabled" ? $"synthetic-registry-{id:D}" : null,
            Id(8, nextAgent).ToString("D"), BlueprintId.ToString("D")),
        features, null, createdAt, createdAt, FixtureIdentity.ActorId.ToString("D"),
        status is "Active" or "Disabled" ? null : new ProvisioningStatusDto("RegisterAgent", 71, null),
        FixtureIdentity.ActorId.ToString("D"), FixtureIdentity.ActorId.ToString("D"),
        Convert.FromBase64String(Version), null,
        new ProvisioningRetryEligibilityDto(status == "Failed" && !scenario.Legacy,
            status == "Failed" && !scenario.Legacy ? "Synthetic failed operation may be retried." : "No replay is advertised."));

    private OperationStatusDto NewOperation(Guid agentId, string type, string status)
    {
        var id = Id(4, ++nextOperation);
        var operation = new OperationStatusDto(id, type, status, null, 0, agentId, DateTime.UtcNow,
            null, null, [], scenario.Legacy ? 1 : 2, scenario.Legacy);
        operation = Transition(operation, status, scenario.CompletionAvailable, updateAgent: false);
        operations.Add(id, operation);
        newestOperationId = id;
        return operation;
    }

    private OperationStatusDto Transition(OperationStatusDto operation, string status, bool available,
        bool registryAccepted = false, bool updateAgent = true)
    {
        var observedAt = DateTime.UtcNow;
        var completed = status == "Completed";
        var registered = completed || registryAccepted ||
            operation.Steps?.Any(item => item.Step == "RegisterAgent" && item.Status == "Completed") == true;
        var currentStep = operation.Type == "Delete" ? "DeleteGatewayMapping" :
            registered ? "VerifyProvisioning" : status is "Running" or "Pending" ? "CreateAgentIdentity" : "RegisterAgent";
        var changed = operation with
        {
            Status = status,
            CurrentStep = currentStep,
            PercentComplete = completed ? 100 : registered ? 90 : status == "Pending" ? 0 : 71,
            CompletedAtUtc = status is "Completed" or "Failed" or "Cancelled" ? observedAt : null,
            Error = status is "Failed" or "RequiresManualIntervention" ? new("SYNTHETIC_OPERATION_ERROR", "Safe fixture diagnostic.") : null,
            Steps = operation.Type == "Delete"
                ? [new("DeleteGatewayMapping", completed ? "Completed" : "Running", completed ? observedAt : null)]
                :
                [
                    new("CreateAgentIdentity", "Completed", operation.StartedAtUtc),
                    new("RegisterAgent", registered ? "Completed" : "Pending", registered ? observedAt : null),
                    new("VerifyProvisioning", completed ? "Completed" : "Pending", completed ? observedAt : null)
                ],
            PollingRecommended = !operation.Legacy && (status is "Pending" or "Running"),
            RequiredAction = operation.Type == "Register" && status == "AwaitingAdministratorAction" ? "CompleteAgent365Registration" : null,
            Agent365RegistrationCompletionAvailable = operation.Type == "Register" &&
                !operation.Legacy && status == "AwaitingAdministratorAction" && available,
            ReplaySupported = false
        };
        if (updateAgent)
        {
            var agent = FindAgent(operation.AgentId);
            var agentStatus = operation.Type == "Delete" ? completed ? "Deleted" : "Deleting" : AgentStatus(status);
            agents[operation.AgentId] = agent with
            {
                Status = agentStatus,
                UpdatedAtUtc = DateTime.UtcNow,
                Provisioning = completed ? null : new(currentStep, changed.PercentComplete, changed.Error?.Code),
                Agent365 = registered && agent.Agent365 is not null
                    ? agent.Agent365 with { InstanceId = $"synthetic-registry-{agent.AgentId:D}" }
                    : agent.Agent365
            };
        }
        return changed;
    }

    private static string AgentStatus(string operationStatus) => operationStatus switch
    {
        "Completed" => "Active",
        "AwaitingAdministratorAction" => "AwaitingAdminApproval",
        "Failed" or "Cancelled" => "Failed",
        "RequiresManualIntervention" => "RequiresManualIntervention",
        _ => "Provisioning"
    };

    private AgentGatewayCredentialDto IssueKey(Guid agentId)
    {
        var keyId = Id(7, ++nextKey);
        var createdAt = DateTime.UtcNow;
        var expiresAt = createdAt.AddHours(1);
        credentials[agentId].Add(new(keyId, createdAt, expiresAt, null));
        // This deliberately invalid string is constructed only for the one-time
        // mutation response. State, audit, exceptions and counters never retain it.
        return new(keyId, $"invalid-browser-fixture-key-{nextKey:D4}-not-a-real-credential", expiresAt);
    }

    private void AddAudit(Guid id, string eventType) => audit[id].Add(new(
        Id(9, ++nextEvent), id, eventType, FixtureIdentity.ActorId.ToString("D"), DateTime.UtcNow,
        new { synthetic = true }));

    private AgentDetailDto FindAgent(Guid id) => agents.TryGetValue(id, out var agent)
        ? agent with { RowVersion = agent.RowVersion.ToArray() }
        : throw Error(HttpStatusCode.NotFound, "No such synthetic agent.", "AGENT_NOT_FOUND");

    internal static GatewayApiResource<T> Resource<T>(T value) => new(value, Version, "browser-fixture-correlation");
    internal static AgentFeaturesDto Features(bool telemetry = false) => new(
        telemetry ? "Agent365AzureMonitor" : "Disabled", false, null, telemetry, telemetry, false);
    private static AgentSummaryDto Summary(AgentDetailDto item) => new(
        item.AgentId, item.ExternalAgentId, item.Name, item.Description, item.Status, item.Environment,
        item.Agent365, item.Features, item.LastActivityAtUtc, item.CreatedAtUtc, item.UpdatedAtUtc);
    // The first timestamp tie is inserted out of order and sorts differently under
    // Guid.CompareTo, so preserving insertion order or .NET GUID order is detectable.
    internal static Guid SeedAgentId(int index) => index switch
    {
        2 => Guid.Parse("ffffffff-ffff-4fff-8fff-000000000002"),
        3 => Guid.Parse("00000000-0000-4000-8000-000000000003"),
        _ => Id(3, index)
    };
    internal static Guid Id(int family, int index) => Guid.Parse($"{family}{family}{family}{family}{family}{family}{family}{family}-{family}{family}{family}{family}-4{family}{family}{family}-8{family}{family}{family}-{index:D12}");

    internal static GatewayApiException Error(HttpStatusCode status, string detail, string code,
        IReadOnlyDictionary<string, string[]>? validation = null) => new(
        status, "Synthetic Gateway response", detail, null, null, code, "browser-fixture-correlation",
        validation ?? new Dictionary<string, string[]>(), null);

    private static GatewayApiTransportException Interrupted() => new(
        "The synthetic mutation response was interrupted. Read back the existing resource.",
        "browser-fixture-correlation", new HttpRequestException("Synthetic response interruption; no network request was sent."));
}
