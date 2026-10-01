using System.Net;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.BrowserHost;

internal sealed record FixtureProtectionControl(string Action);

internal sealed partial class FixtureState
{
    private static readonly Guid FixtureConnectionId = Guid.Parse("11111111-1111-4111-8111-111111111101");
    private static readonly Guid FixtureInventoryId = Guid.Parse("11111111-1111-4111-8111-111111111102");
    private static readonly Guid FixtureProfileId = Guid.Parse("11111111-1111-4111-8111-111111111103");
    private static readonly Guid FixtureFirstSit = Guid.Parse("11111111-1111-4111-8111-111111111104");
    private static readonly Guid FixtureSecondSit = Guid.Parse("11111111-1111-4111-8111-111111111105");
    private readonly Dictionary<Guid, (ProtectionOperationReviewSummaryDto Summary, string Version, DateTime Expires)> protectionReviews = [];
    private readonly Dictionary<Guid, ProtectionAdminOperationDto> protectionOperations = [];
    private readonly Dictionary<Guid, PurviewCompanionLaunchDto> companionLaunches = [];
    private readonly HashSet<Guid> confirmedProtection = [];
    private readonly HashSet<Guid> acceptedProtection = [];
    private PurviewTenantConnectionDto? fixtureConnection;
    private PurviewDlpProfileDto? fixtureProfile;
    private Guid? newestProtectionOperation;
    private Guid? latestConnectionCompletionReview;
    private bool interruptConnectionCompletion;
    private int protectionVersion;
    private bool ProtectionSelected => scenario.Protection != "none";
    private bool ProtectionInstalled => ProtectionSelected && scenario.Protection != "core";
    private static string FixtureHash(char character) => "sha256:" + new string(character, 64);

    private void InitializeProtection()
    {
        protectionReviews.Clear();
        protectionOperations.Clear();
        companionLaunches.Clear();
        confirmedProtection.Clear();
        acceptedProtection.Clear();
        runtimeReviews.Clear();
        runtimeReports.Clear();
        newestProtectionOperation = latestRuntimeOperation = null;
        latestConnectionCompletionReview = null;
        interruptConnectionCompletion = false;
        fixtureConnection = null;
        fixtureProfile = null;
        protectionVersion = 1;
        if (!ProtectionInstalled)
            return;
        if (scenario.Protection is not ("connection" or "connection-unknown"))
            fixtureConnection = ConnectionDto(scenario.Protection is "connection-pending" or "connection-expired" ? "AwaitingAdministrator" : "Connected");
        if (scenario.Protection is "connection-pending" or "connection-expired")
        {
            var id = Guid.NewGuid();
            newestProtectionOperation = id;
            var launch = Launch(id, scenario.Protection == "connection-expired"
                ? DateTimeOffset.UtcNow.AddSeconds(-1) : null);
            companionLaunches[id] = launch;
            fixtureConnection = ConnectionDto("AwaitingAdministrator") with { ExpiresAtUtc = launch.ExpiresAtUtc.UtcDateTime };
            protectionOperations[id] = ProtectionOperation(id, "ConnectPurviewTenant", "AwaitingAdministrator",
                "PurviewTenantConnection", FixtureConnectionId.ToString("D"));
            acceptedProtection.Add(id);
        }
        if (scenario.Protection is not ("connection" or "connection-unknown" or "connection-pending" or "connection-expired"))
        {
            var mode = scenario.Protection switch { "simulation" => "SimulationWithTips", "off" => "Disabled", _ => "Enforce" };
            var expiry = scenario.Protection == "expired" ? now.AddSeconds(-1) : now.AddMinutes(10);
            fixtureProfile = new(FixtureProfileId, BlueprintClientId, "Synthetic shared blueprint policy",
                FixtureFirstSit, "Synthetic employee identifier", mode == "Enforce" ? "Enforce" : "AuditOnly",
                ["UploadText", "DownloadText"], [new("UploadText", "Block")],
                mode == "Enforce" ? "Ready" : mode == "Disabled" ? "Disabled" : "SimulationReady",
                Readiness(mode == "Enforce", expiry), "synthetic-policy", "synthetic-rule", now, Version,
                mode, SelectedTypes(), FixtureHash('a'), mode == "Enforce" ? expiry : null);
            if (scenario.Protection is "inventory-stale" or "inventory-wrong")
                fixtureProfile = fixtureProfile with { Readiness = fixtureProfile.Readiness with
                {
                    IsReady = false, ValidUntilUtc = now.AddSeconds(-1), Blockers = ["PURVIEW_INVENTORY_STALE"]
                } };
        }
        ApplyProtectionToAgents(initializeChoices: true);
    }

    private object ProtectionSnapshot() => new
    {
        selected = ProtectionSelected, installed = ProtectionInstalled,
        connectionId = FixtureConnectionId, inventoryGenerationId = FixtureInventoryId,
        profileId = FixtureProfileId, profileVersion = fixtureProfile?.RowVersion,
        policyMode = fixtureProfile?.PolicyMode, connectionStatus = fixtureConnection?.Status,
        latestOperationId = newestProtectionOperation, runtimeOperationId = latestRuntimeOperation,
        completionReviewId = latestConnectionCompletionReview,
        expiresAtUtc = fixtureConnection?.ExpiresAtUtc,
        classifiers = Classifiers(), reportCount = runtimeReports.Count
    };

    internal GatewayApiResource<ProtectionCapabilitiesResponse> GetCapabilities() => Resource(new ProtectionCapabilitiesResponse(
        !ProtectionSelected ? [] :
        [new(FixtureConnectionId, "Purview", ProtectionInstalled ? "Installed" : "NotInstalled",
            new(null, null, null, null, null, null, null, null, null), now, null, Version),
         new(FixtureInventoryId, "PromptShields", ProtectionInstalled ? "Installed" : "NotInstalled",
            new(null, null, null, null, null, null, null, null, null), now, null, Version)]));
    internal GatewayApiResource<PurviewTenantConnectionResponse> GetConnection() => Resource(new PurviewTenantConnectionResponse(fixtureConnection));
    internal GatewayApiResource<PurviewDlpProfileListResponse> GetProfiles() => Resource(new PurviewDlpProfileListResponse(
        fixtureProfile is null ? [] : [fixtureProfile]));
    internal GatewayApiResource<PurviewSensitiveInformationTypeListResponse> GetClassifierInventory()
    {
        RequireProtection(nameof(GetClassifierInventory));
        return Resource(new PurviewSensitiveInformationTypeListResponse(FixtureInventoryId,
            scenario.Protection == "inventory-wrong" ? BlueprintId : FixtureIdentity.TenantId, now,
            scenario.Protection == "inventory-stale" ? now.AddSeconds(-1) : now.AddMinutes(10),
            scenario.Protection == "inventory-stale", Classifiers()));
    }

    internal GatewayApiResource<ProtectionOperationReviewTicket> ReviewConnection(ReviewPurviewTenantConnectionRequest request)
    {
        RequireProtection(nameof(ReviewConnection));
        if (request.TenantId != FixtureIdentity.TenantId || request.ExpectedRowVersion != (fixtureConnection?.RowVersion ?? "*"))
            throw Error(HttpStatusCode.PreconditionFailed, "The connection binding changed.", "CONCURRENCY_CONFLICT");
        return Review(new(FixtureIdentity.TenantId, "ConnectPurviewTenant", "PurviewTenantConnection",
            FixtureIdentity.TenantId.ToString("D"), null, null, null, null, [], [], "Tenant", "Application",
            "Synthetic review only; connection still requires independent verification."), request.ExpectedRowVersion);
    }

    internal GatewayApiResource<ProtectionOperationReviewTicket> ReviewConnectionCompletion(Guid operationId, Guid generationId,
        PurviewTenantConnectionEvidenceDto evidence, string version)
    {
        RequireProtection(nameof(ReviewConnectionCompletion));
        if (!protectionOperations.TryGetValue(operationId, out var source) ||
            source is not { Type: "ConnectPurviewTenant", Status: "AwaitingAdministrator" } ||
            !companionLaunches.TryGetValue(operationId, out var launch) || launch.ExpiresAtUtc <= DateTimeOffset.UtcNow ||
            launch.InventoryGenerationId != generationId || evidence.TenantId != FixtureIdentity.TenantId ||
            evidence.AdministratorObjectId != FixtureIdentity.ActorId || evidence.InventoryExpiresAtUtc != launch.ExpiresAtUtc ||
            fixtureConnection?.RowVersion != version)
            throw Error(HttpStatusCode.BadRequest, "The companion evidence does not match this fixture operation.", "PROTECTION_CONFIRMATION_INVALID");
        return Review(new(FixtureIdentity.TenantId, "CompletePurviewTenantConnection", "PurviewTenantConnection",
            FixtureConnectionId.ToString("D"), null, null, null, null, [], [], "Tenant", "Application",
            "Evidence submission is not connection verification.", operationId, generationId,
            PurviewTenantConnectionEvidenceDigest.Compute(operationId, generationId, evidence)), version);
    }

    internal GatewayApiResource<ProtectionOperationConfirmationTicket> ConfirmProtection(ProtectionOperationReviewTicket ticket)
    {
        RequireProtection(nameof(ConfirmProtection));
        if (!protectionReviews.TryGetValue(ticket.ReviewTokenId, out var stored) || !ticket.IsAvailable ||
            stored.Expires <= DateTime.UtcNow || stored.Summary != ticket.Review && stored.Summary.TargetIdentifier != ticket.Review.TargetIdentifier)
            throw Error(HttpStatusCode.Conflict, "The review is no longer available.", "PROTECTION_CONFIRMATION_INVALID");
        if (scenario.Protection == "policy-conflict" && stored.Summary.TargetType == "DlpProfile")
            throw Error(HttpStatusCode.PreconditionFailed, "The shared policy changed while it was reviewed.", "CONCURRENCY_CONFLICT");
        _ = ticket.Consume();
        confirmedProtection.Add(ticket.ReviewTokenId);
        return Resource(new ProtectionOperationConfirmationTicket(new(ticket.ReviewTokenId, ticket.ReviewTokenId,
            $"synthetic-confirmation-{ticket.ReviewTokenId:D}", stored.Expires), ticket.Review, stored.Version));
    }

    internal GatewayApiResource<ProtectionOperationAcceptedResponse> StartConnection(ProtectionOperationConfirmationTicket ticket)
    {
        var id = Accept(ticket, "ConnectPurviewTenant");
        var launch = Launch(id);
        fixtureConnection = ConnectionDto("AwaitingAdministrator") with { ExpiresAtUtc = launch.ExpiresAtUtc.UtcDateTime };
        companionLaunches[id] = launch;
        protectionOperations[id] = ProtectionOperation(id, "ConnectPurviewTenant", "AwaitingAdministrator",
            "PurviewTenantConnection", FixtureConnectionId.ToString("D"));
        if (scenario.Protection == "connection-unknown") throw Interrupted();
        return Resource(new ProtectionOperationAcceptedResponse(id, "AwaitingAdministrator", id, launch));
    }

    internal GatewayApiResource<ProtectionOperationAcceptedResponse> CompleteConnection(Guid sourceOperation,
        PurviewTenantConnectionEvidenceDto evidence, ProtectionOperationConfirmationTicket ticket)
    {
        if (!protectionOperations.TryGetValue(sourceOperation, out var source) ||
            source is not { Type: "ConnectPurviewTenant", Status: "AwaitingAdministrator" } ||
            fixtureConnection?.Status != "AwaitingAdministrator" ||
            ticket.Review.SourceOperationId != sourceOperation ||
            ticket.Review.EvidenceDigest != PurviewTenantConnectionEvidenceDigest.Compute(sourceOperation, FixtureInventoryId, evidence))
            throw Error(HttpStatusCode.BadRequest, "Companion completion changed after review.", "PROTECTION_CONFIRMATION_INVALID");
        var id = Accept(ticket, "CompletePurviewTenantConnection");
        latestConnectionCompletionReview = id;
        fixtureConnection = ConnectionDto("PendingVerification") with { AuthorityKind = "InteractiveSubmissionUnverified" };
        protectionOperations[id] = ProtectionOperation(id, "CompletePurviewTenantConnection", "Submitted",
            "PurviewTenantConnection", FixtureConnectionId.ToString("D")) with { ReadbackReferenceId = sourceOperation };
        protectionOperations[sourceOperation] = source with
        {
            Status = "Pending", RequiredAction = null, UpdatedAtUtc = DateTime.UtcNow
        };
        newestProtectionOperation = sourceOperation;
        if (interruptConnectionCompletion)
        {
            interruptConnectionCompletion = false;
            throw Interrupted();
        }
        return Resource(new ProtectionOperationAcceptedResponse(sourceOperation, "Pending", source.CorrelationId));
    }

    internal GatewayApiResource<ProtectionAdminOperationResponse> GetProtectionOperation(Guid id)
    {
        RequireProtection(nameof(GetProtectionOperation));
        if (!protectionOperations.TryGetValue(id, out var operation))
            throw Error(HttpStatusCode.NotFound, "No matching synthetic protection operation.", "NOT_FOUND");
        var launch = operation is { Type: "ConnectPurviewTenant", Status: "AwaitingAdministrator" } &&
            operation.ActorObjectId == FixtureIdentity.ActorId.ToString("D")
            ? companionLaunches.GetValueOrDefault(id) : null;
        return Resource(new ProtectionAdminOperationResponse(operation, launch));
    }

    internal GatewayApiResource<ProtectionOperationReviewTicket> ReviewPolicy(ReviewPurviewDlpProfileOperationRequest request)
    {
        RequireProtection(nameof(ReviewPolicy));
        var types = request.SensitiveInformationTypes;
        if (request.BlueprintApplicationId != BlueprintClientId || request.TenantConnectionId != FixtureConnectionId ||
            request.ProfileId != fixtureProfile?.Id || request.ExpectedRowVersion != (fixtureProfile?.RowVersion ?? "*") ||
            fixtureProfile is not null && !request.AcknowledgeSharedPolicyImpact || types is null || types.Count is < 1 or > 100 ||
            types.Select(item => item.SensitiveInformationTypeId).Distinct().Count() != types.Count ||
            types.Any(item => item.InventoryGenerationId != FixtureInventoryId ||
                !Classifiers().Any(type => type.Id == item.SensitiveInformationTypeId && type.ExactName == item.ExactName)) ||
            request.PolicyMode is not ("Enforce" or "SimulationWithTips" or "SimulationWithoutTips" or "Disabled"))
            throw Error(HttpStatusCode.PreconditionFailed, "The reviewed shared policy binding is invalid or stale.", "CONCURRENCY_CONFLICT");
        var normalized = types.Select(item => item with
        {
            MinCount = item.MinCount ?? 1, MaxCount = item.MaxCount ?? -1,
            MinConfidence = item.MinConfidence ?? 75, MaxConfidence = item.MaxConfidence ?? 100
        }).ToArray();
        if (!normalized.All(AgentProtectionUiMapping.HasExplicitThresholds))
            throw Error(HttpStatusCode.BadRequest, "The thresholds are invalid.", "VALIDATION_ERROR");
        return Review(new(FixtureIdentity.TenantId, "CreateOrUpdateDlpProfile", "DlpProfile", FixtureProfileId.ToString("D"),
            BlueprintClientId, normalized[0].SensitiveInformationTypeId, normalized[0].ExactName, request.Mode,
            request.Activities, request.Actions, "Individual", "Application", "Configuration alone is not enforcement.",
            PolicyMode: request.PolicyMode, SensitiveInformationTypes: normalized, AffectsAllBlueprintAgents: fixtureProfile is not null),
            request.ExpectedRowVersion);
    }

    internal GatewayApiResource<ProtectionOperationAcceptedResponse> StartPolicy(ProtectionOperationConfirmationTicket ticket)
    {
        var id = Accept(ticket, "CreateOrUpdateDlpProfile");
        var types = ticket.Review.SensitiveInformationTypes!;
        fixtureProfile = new(FixtureProfileId, BlueprintClientId, "Synthetic shared blueprint policy",
            types[0].SensitiveInformationTypeId, types[0].ExactName, ticket.Review.Mode!, ticket.Review.Activities,
            ticket.Review.Actions, "Pending", Readiness(false, DateTime.UtcNow.AddMinutes(10)) with { Readback = "Pending" },
            "synthetic-policy", "synthetic-rule", null, NextProtectionVersion(), ticket.Review.PolicyMode, types);
        protectionOperations[id] = ProtectionOperation(id, "CreateOrUpdateDlpProfile", "Pending", "DlpProfile", FixtureProfileId.ToString("D"));
        ApplyProtectionToAgents();
        if (scenario.Protection == "policy-unknown") throw Interrupted();
        return Resource(new ProtectionOperationAcceptedResponse(id, "Pending", id));
    }

    internal GatewayApiResource<ProtectionOperationReviewTicket> ReviewPolicyReadback(Guid id, string version)
    {
        RequireProtection(nameof(ReviewPolicyReadback));
        if (fixtureProfile is null || fixtureProfile.Id != id || fixtureProfile.RowVersion != version)
            throw Error(HttpStatusCode.PreconditionFailed, "The shared profile changed.", "CONCURRENCY_CONFLICT");
        return Review(new(FixtureIdentity.TenantId, "ReconcileDlpProfile", "DlpProfile", id.ToString("D"),
            BlueprintClientId, fixtureProfile.SensitiveInformationTypeId, fixtureProfile.SensitiveInformationTypeName,
            fixtureProfile.Mode, fixtureProfile.Activities, fixtureProfile.Actions, "Individual", "Application",
            "Readback is not runtime proof.", PolicyMode: fixtureProfile.PolicyMode,
            SensitiveInformationTypes: fixtureProfile.SensitiveInformationTypes, AffectsAllBlueprintAgents: true), version);
    }

    internal GatewayApiResource<ProtectionOperationAcceptedResponse> ReconcilePolicy(Guid profileId, ProtectionOperationConfirmationTicket ticket)
    {
        if (profileId != FixtureProfileId) throw RejectUnexpected(nameof(ReconcilePolicy));
        var id = Accept(ticket, "ReconcileDlpProfile");
        protectionOperations[id] = ProtectionOperation(id, "ReconcileDlpProfile", "Pending", "DlpProfile", FixtureProfileId.ToString("D"));
        return Resource(new ProtectionOperationAcceptedResponse(id, "Pending", id));
    }

    public object AdvanceProtection(FixtureProtectionControl control)
    {
        lock (sync)
        {
            RequireProtection(nameof(AdvanceProtection));
            if (control.Action is "connection-verified" or "connection-failed" &&
                newestProtectionOperation is { } connectionId &&
                protectionOperations.TryGetValue(connectionId, out var connectionOperation) &&
                connectionOperation is { Type: "ConnectPurviewTenant", Status: "Pending" })
            {
                var failed = control.Action == "connection-failed";
                var failureCode = failed ? "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED" : null;
                fixtureConnection = failed ? ConnectionDto("VerificationFailed") with
                {
                    AuthorityKind = "VerificationFailed", ActiveInventoryGenerationId = null,
                    AuthorizedAtUtc = null, ExpiresAtUtc = null, LastVerifiedAtUtc = null, LastFailureCode = failureCode
                } : ConnectionDto("Connected");
                protectionOperations[connectionId] = connectionOperation with
                {
                    Status = failed ? "RequiresManualIntervention" : "Completed", FailureCode = failureCode,
                    RetryDisposition = failed ? "RequiresManualIntervention" : "NotApplicable",
                    RequiredAction = failed ? "Retry" : null,
                    RequiresManualIntervention = failed, CompletedAtUtc = failed ? null : DateTime.UtcNow,
                    UpdatedAtUtc = DateTime.UtcNow,
                    Steps = ConnectionSteps(failed)
                };
            }
            else if (control.Action == "lose-next-connection-completion-response" &&
                fixtureConnection?.Status == "AwaitingAdministrator")
                interruptConnectionCompletion = true;
            else if (control.Action == "policy-readback" && fixtureProfile is not null &&
                newestProtectionOperation is { } policyId &&
                protectionOperations.TryGetValue(policyId, out var policyOperation) &&
                policyOperation is { Type: "CreateOrUpdateDlpProfile" or "ReconcileDlpProfile", Status: "Pending" })
            {
                fixtureProfile = fixtureProfile with { Status = fixtureProfile.PolicyMode == "Enforce" ? "Ready" :
                    fixtureProfile.PolicyMode == "Disabled" ? "Disabled" : "SimulationReady",
                    Readiness = Readiness(false, DateTime.UtcNow.AddMinutes(10)), LastReadbackAtUtc = DateTime.UtcNow };
                protectionOperations[policyId] = policyOperation with
                {
                    Status = "Completed", CompletedAtUtc = DateTime.UtcNow, UpdatedAtUtc = DateTime.UtcNow,
                    RequiredAction = fixtureProfile.PolicyMode == "Enforce" ? "ValidateRuntime" : null
                };
            }
            else if (control.Action == "expire" && fixtureProfile is not null)
                fixtureProfile = fixtureProfile with { Readiness = fixtureProfile.Readiness with { ValidUntilUtc = DateTime.UtcNow.AddSeconds(-1) } };
            else throw new ArgumentException("The fixture action is unsupported or does not match its current operation state.");
            ApplyProtectionToAgents();
            return SnapshotCore();
        }
    }

    private IReadOnlyList<ProtectionAdminOperationStepDto> ConnectionSteps(bool failed) =>
        new[] { "ValidateReviewedIntent", "DiscoverProviderState", "ApplyReviewedMutation", "RecordExactReadback",
            "VerifyPropagation", "AttestTokenRoles", "ValidateRuntimeVerdict", "Complete" }
        .Select((step, index) =>
        {
            var status = failed ? index switch { 0 => "Completed", 1 => "RequiresManualIntervention", _ => "Pending" } :
                step is "ApplyReviewedMutation" or "VerifyPropagation" or "AttestTokenRoles" or "ValidateRuntimeVerdict"
                    ? "Skipped" : "Completed";
            var needsAttention = status == "RequiresManualIntervention";
            return new ProtectionAdminOperationStepDto(Guid.NewGuid(), index, step, status,
                status == "Pending" ? 0 : 1, needsAttention ? "RequiresManualIntervention" : "NotApplicable",
                null, false, needsAttention, null, needsAttention ? "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED" : null,
                status == "Pending" ? null : now, status is "Completed" or "Skipped" ? DateTime.UtcNow : null);
        }).ToArray();

    private GatewayApiResource<ProtectionOperationReviewTicket> Review(ProtectionOperationReviewSummaryDto summary, string version)
    {
        var id = Guid.NewGuid();
        newestProtectionOperation = id;
        var expires = DateTime.UtcNow.AddMinutes(5);
        protectionReviews[id] = (summary, version, expires);
        protectionOperations[id] = ProtectionOperation(id, summary.OperationType, "AwaitingConfirmation", summary.TargetType, summary.TargetIdentifier);
        return Resource(new ProtectionOperationReviewTicket(new(id, $"synthetic-review-{id:D}", FixtureHash('a'), expires, summary), version));
    }

    private Guid Accept(ProtectionOperationConfirmationTicket ticket, string type)
    {
        RequireProtection(nameof(Accept));
        var id = ticket.ReviewTokenId;
        if (ticket.Review.OperationType != type || !ticket.IsAvailable || ticket.ExpiresAtUtc <= DateTime.UtcNow ||
            !confirmedProtection.Contains(id) || !acceptedProtection.Add(id))
            throw Error(HttpStatusCode.Conflict, "Only a fresh reviewed confirmation can be used.", "PROTECTION_CONFIRMATION_INVALID");
        _ = ticket.Consume();
        newestProtectionOperation = id;
        return id;
    }

    private void RequireProtection(string method)
    {
        if (!ProtectionInstalled) throw RejectUnexpected(method);
    }
    private string NextProtectionVersion() => Convert.ToBase64String(BitConverter.GetBytes((long)++protectionVersion).Reverse().ToArray());
    private PurviewTenantConnectionDto ConnectionDto(string status) => new(FixtureConnectionId, FixtureIdentity.TenantId,
        status, "InteractiveDelegatedAdministrator", null, null, FixtureInventoryId, now, now.AddMinutes(10),
        status == "Connected" ? now : null, null, Version);
    private static PurviewSensitiveInformationTypeDto[] Classifiers() =>
        [new(FixtureFirstSit, "Synthetic employee identifier", "Fixture"), new(FixtureSecondSit, "Synthetic project code", "Fixture")];
    private static PurviewSensitiveInformationTypeSelectionDto[] SelectedTypes() => Classifiers().Select(item =>
        new PurviewSensitiveInformationTypeSelectionDto(FixtureInventoryId, item.Id, item.ExactName, 1, -1, 75, 100)).ToArray();
    private ProtectionReadinessDto Readiness(bool ready, DateTime expiry) => new("Installed", "Ready", "Ready", "Ready",
        ready ? "Ready" : "NotChecked", ready, ready ? [] : ["PURVIEW_RUNTIME_SAMPLES_REQUIRED"], now, ValidUntilUtc: expiry);
    private static PurviewCompanionLaunchDto Launch(Guid id, DateTimeOffset? expiry = null)
    {
        var expires = expiry ?? DateTimeOffset.UtcNow.AddMinutes(10);
        return new(id, FixtureInventoryId, expires, "Automation/Connect-PurviewTenant.ps1",
            ["-NoLogo", "-NoProfile", "-File", "Automation/Connect-PurviewTenant.ps1", "-OperationId", id.ToString("D"),
                "-TenantId", FixtureIdentity.TenantId.ToString("D"), "-AdministratorObjectId", FixtureIdentity.ActorId.ToString("D"),
                "-InventoryGenerationId", FixtureInventoryId.ToString("D"), "-ExpiresAtUtc", expires.ToString("O")]);
    }
    private ProtectionAdminOperationDto ProtectionOperation(Guid id, string type, string status, string targetType, string target) =>
        new(id, 1, type, status, FixtureIdentity.TenantId, FixtureIdentity.ActorId.ToString("D"), targetType, target,
            FixtureHash('a'), id, Version, "NotApplicable", 0, 1, null, false, status == "RequiresManualIntervention", id, null,
            null, type == "ConnectPurviewTenant" && status == "AwaitingAdministrator" ? "CompletePurviewTenantConnection" : null,
            [], now, now, status == "Completed" ? DateTime.UtcNow : null, DateTime.UtcNow, [], Version);
    private void ApplyProtectionToAgents(bool initializeChoices = false)
    {
        foreach (var (id, agent) in agents.ToArray())
            agents[id] = agent with { Features = (agent.Features ?? Features()) with
            {
                PromptShieldEnabled = ProtectionInstalled, PromptShieldEffectivelyEnabled = ProtectionInstalled,
                PromptShieldCapabilityStatus = ProtectionInstalled ? "Installed" : "NotInstalled",
                PurviewEnabled = initializeChoices ? fixtureProfile is not null : agent.Features?.PurviewEnabled == true,
                PurviewPolicyMode = fixtureProfile?.PolicyMode,
                PurviewMode = fixtureProfile?.Mode, PurviewProfileStatus = fixtureProfile?.Status,
                PurviewEffectivelyEnabled = (initializeChoices ? fixtureProfile is not null : agent.Features?.PurviewEnabled == true) &&
                    fixtureProfile?.Readiness.IsReady == true,
                PurviewReadiness = fixtureProfile?.Readiness,
                PurviewDlpProfile = fixtureProfile is null ? null : new(FixtureProfileId, BlueprintClientId, fixtureProfile.RowVersion)
            } };
    }
}
