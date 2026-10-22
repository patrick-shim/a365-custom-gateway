using Gateway.Api.Infrastructure;
using Gateway.Application.Purview.Commands;
using Gateway.Application.Purview.Queries;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.Purview;

static class PurviewConnectorBackendChecks
{
    public static async Task RunAsync()
    {
        static void Check(bool condition, string message)
        {
            if (!condition) throw new Exception(message);
        }

        var now = DateTime.UtcNow;
        var tenantId = Guid.NewGuid();
        var connectorId = Guid.NewGuid();
        var running = new PurviewConnectorOperation
        {
            Id = Guid.NewGuid(),
            TenantId = tenantId,
            ConnectorInstanceId = connectorId,
            Status = PurviewConnectorOperationStatus.Running,
            ExpiresAtUtc = now.AddMinutes(5)
        };
        Check(PurviewConnectorDispatcher.RequiresCommandPublication(running, resultExists: false, utcNow: now),
            "A Running operation in the post-commit/pre-file crash window was not rescheduled for publication.");
        Check(!PurviewConnectorDispatcher.RequiresCommandPublication(running, resultExists: true, utcNow: now),
            "A completed transport result was incorrectly rescheduled for command publication.");
        running.Status = PurviewConnectorOperationStatus.Succeeded;
        running.ResultHash = new string('c', 64);
        Check(!PurviewConnectorDispatcher.RequiresCommandPublication(running, resultExists: false, utcNow: now),
            "A terminal operation was incorrectly rescheduled for command publication.");
        var checkpoint = new PurviewConnectorCheckpoint(tenantId, connectorId, 1, now);
        running.Generation = 1;
        Check(PurviewConnectorDispatcher.CheckpointCovers(checkpoint, running),
            "An authenticated connector checkpoint did not permit cleanup of durably accepted evidence.");
        Check(!PurviewConnectorDispatcher.CheckpointCovers(
                checkpoint with { HighestCompletedGeneration = 0 }, running),
            "A checkpoint behind the accepted operation permitted transport cleanup.");

        var canonicalIssuedAt = now.AddTicks(-(now.Ticks % TimeSpan.TicksPerMicrosecond));
        var canonicalExpiresAt = canonicalIssuedAt.AddMinutes(5);
        var persistedOperation = new PurviewConnectorOperation
        {
            Id = Guid.NewGuid(),
            TenantId = tenantId,
            ConnectorInstanceId = connectorId,
            Type = PurviewConnectorOperationType.RefreshCatalog,
            Generation = 2,
            RequestHash = new string('e', 64),
            IssuedAtUtc = canonicalIssuedAt,
            ExpiresAtUtc = canonicalExpiresAt
        };
        var legacyPrePersistenceCommand = new PurviewConnectorCommand(
            persistedOperation.Id,
            tenantId,
            connectorId,
            PurviewConnectorAction.RefreshCatalog,
            persistedOperation.Generation,
            persistedOperation.RequestHash,
            canonicalIssuedAt.AddTicks(7),
            canonicalExpiresAt.AddTicks(7));
        Check(PurviewConnectorDispatcher.CommandMatchesOperation(legacyPrePersistenceCommand, persistedOperation),
            "A command issued before PostgreSQL microsecond truncation could not be recovered after reload.");
        var canonicalCommand = PurviewConnectorDispatcher.CreateCommand(persistedOperation);
        Check(canonicalCommand.IssuedAtUtc.Ticks % TimeSpan.TicksPerMicrosecond == 0 &&
              canonicalCommand.ExpiresAtUtc.Ticks % TimeSpan.TicksPerMicrosecond == 0,
            "A new connector command was not canonicalized to PostgreSQL timestamp precision.");
        Check(!PurviewConnectorDispatcher.CommandMatchesOperation(
                legacyPrePersistenceCommand with { IssuedAtUtc = canonicalIssuedAt.AddTicks(TimeSpan.TicksPerMicrosecond) },
                persistedOperation),
            "A connector command differing by a durable microsecond was accepted during recovery.");
        Check(!PurviewConnectorDispatcher.CommandMatchesOperation(
                legacyPrePersistenceCommand with { RequestHash = new string('f', 64) }, persistedOperation) &&
              !PurviewConnectorDispatcher.CommandMatchesOperation(
                legacyPrePersistenceCommand with { Generation = persistedOperation.Generation + 1 }, persistedOperation) &&
              !PurviewConnectorDispatcher.CommandMatchesOperation(
                legacyPrePersistenceCommand with { OperationId = Guid.NewGuid() }, persistedOperation),
            "Connector recovery weakened an immutable command binding.");

        var timedOutWithoutResult = new PurviewConnectorOperation
        {
            Status = PurviewConnectorOperationStatus.TimedOut,
            ExpiresAtUtc = now.AddMinutes(-11)
        };
        Check(PurviewConnectorDispatcher.TerminalTransportGraceElapsed(timedOutWithoutResult, now),
            "A timed-out operation without a result never became eligible for bounded transport cleanup.");
        timedOutWithoutResult.ExpiresAtUtc = now.AddMinutes(-9);
        Check(!PurviewConnectorDispatcher.TerminalTransportGraceElapsed(timedOutWithoutResult, now),
            "Terminal transport cleanup did not preserve the late-result grace period.");
        timedOutWithoutResult.ExpiresAtUtc = now.AddMinutes(-11);
        timedOutWithoutResult.ResultHash = new string('d', 64);
        Check(!PurviewConnectorDispatcher.TerminalTransportGraceElapsed(timedOutWithoutResult, now),
            "A terminal operation with authenticated result evidence entered the no-result cleanup path.");

        var heartbeatState = new PurviewConnectorStateRecord
        {
            TenantId = tenantId,
            ConnectorInstanceId = connectorId,
            State = PurviewConnectorState.Connected,
            LastHeartbeatAtUtc = now.Subtract(PurviewConnectorDispatcher.HeartbeatStaleAfter).AddSeconds(-1),
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
            CatalogRetrievedAtUtc = now.AddMinutes(-1),
            CatalogVerificationStatus = "Verified",
            PolicyCount = 2
        };
        Check(PurviewConnectorDispatcher.ReconcileHeartbeatAvailability(
                  heartbeatState, hasAcceptedCatalog: true, now) == "PurviewConnectorLivenessLost" &&
              heartbeatState.State == PurviewConnectorState.Degraded &&
              heartbeatState.LastFailureCode == "PURVIEW_CONNECTOR_UNAVAILABLE" &&
              heartbeatState.CatalogVerificationStatus == "Verified" && heartbeatState.PolicyCount == 2,
            "A stale authenticated heartbeat did not degrade readiness while retaining the accepted catalog.");
        var importedWithoutHeartbeat = new PurviewConnectorStateRecord
        {
            TenantId = tenantId,
            ConnectorInstanceId = connectorId,
            State = PurviewConnectorState.Connected,
            LastHeartbeatAtUtc = null,
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
            CatalogRetrievedAtUtc = now,
            CatalogVerificationStatus = "Verified",
            PolicyCount = 2
        };
        Check(PurviewConnectorDispatcher.ReconcileHeartbeatAvailability(
                  importedWithoutHeartbeat, hasAcceptedCatalog: true, now) is null &&
              importedWithoutHeartbeat.State == PurviewConnectorState.Connected,
            "A newly imported connection was degraded before its first thirty-second heartbeat window elapsed.");
        Check(PurviewConnectorDispatcher.ReconcileHeartbeatAvailability(
                  importedWithoutHeartbeat, hasAcceptedCatalog: true,
                  now.Add(PurviewConnectorDispatcher.HeartbeatStaleAfter).AddSeconds(1)) ==
              "PurviewConnectorLivenessLost" &&
              importedWithoutHeartbeat.State == PurviewConnectorState.Degraded,
            "A connection with no heartbeat remained ready after its startup heartbeat window elapsed.");
        heartbeatState.LastHeartbeatAtUtc = now;
        Check(PurviewConnectorDispatcher.ReconcileHeartbeatAvailability(
                  heartbeatState, hasAcceptedCatalog: true, now) == "PurviewConnectorLivenessRestored" &&
              heartbeatState.State == PurviewConnectorState.Connected && heartbeatState.LastFailureCode is null,
            "A recovered authenticated heartbeat did not restore a liveness-only degraded connection.");
        heartbeatState.State = PurviewConnectorState.NotConfigured;
        heartbeatState.LastHeartbeatAtUtc = null;
        heartbeatState.CreatedAtUtc = now.Subtract(PurviewConnectorDispatcher.HeartbeatStaleAfter).AddSeconds(-1);
        heartbeatState.UpdatedAtUtc = heartbeatState.CreatedAtUtc;
        Check(PurviewConnectorDispatcher.ReconcileHeartbeatAvailability(
                  heartbeatState, hasAcceptedCatalog: false, now) == "PurviewConnectorLivenessLost" &&
              heartbeatState.State == PurviewConnectorState.Disconnected,
            "A missing heartbeat without an accepted catalog did not report a disconnected connector.");

        foreach (var stateValue in Enum.GetValues<PurviewConnectorState>())
        {
            var canConnect = stateValue is PurviewConnectorState.NotConfigured or PurviewConnectorState.Disconnected;
            var canRefresh = stateValue is PurviewConnectorState.Connected or PurviewConnectorState.Degraded;
            Check(PurviewConnectorStore.IsLegalSubmissionState(PurviewConnectorOperationType.Connect, stateValue) == canConnect,
                $"Connect legality was incorrect for {stateValue}.");
            Check(PurviewConnectorStore.IsLegalSubmissionState(PurviewConnectorOperationType.RefreshCatalog, stateValue) == canRefresh,
                $"Refresh legality was incorrect for {stateValue}.");
        }

        var agentIdentityId = Guid.NewGuid();
        var policy = new PurviewExistingPolicy(
            Guid.NewGuid(), "Existing policy", "Enable", ["Application"], [agentIdentityId], true,
            new string('a', 64), [agentIdentityId]);
        var assignment = new AgentPolicyAssignment
        {
            PolicyId = policy.Id,
            AgentIdentityId = agentIdentityId,
            AssignedRevision = policy.Revision,
            Status = "Assigned"
        };
        Check(PurviewConnectorDispatcher.AssignmentFailure(
                assignment, new Dictionary<Guid, PurviewExistingPolicy> { [policy.Id] = policy }) is null,
            "An unchanged confirmed assignment was invalidated by catalog acceptance.");
        Check(PurviewConnectorDispatcher.AssignmentFailure(
                assignment, new Dictionary<Guid, PurviewExistingPolicy>
                {
                    [policy.Id] = policy with { Revision = new string('b', 64) }
                }) == "ASSIGNMENT_POLICY_REVISION_CHANGED",
            "A changed policy revision was not marked for operator attention.");
        Check(PurviewConnectorDispatcher.AssignmentFailure(
                assignment, new Dictionary<Guid, PurviewExistingPolicy>
                {
                    [policy.Id] = policy with { AllAccountsApplicationIds = [] }
                }) == "ASSIGNMENT_POLICY_SCOPE_CHANGED",
            "A removed individual-agent scope was not marked for operator attention.");

        var state = new PurviewConnectorStateRecord
        {
            Id = Guid.NewGuid(),
            TenantId = tenantId,
            ConnectorInstanceId = connectorId,
            ConnectorProfile = "LocalWindows",
            State = PurviewConnectorState.Connected,
            UpdatedAtUtc = now,
            RowVersion = Guid.NewGuid().ToByteArray()
        };
        var operation = new PurviewConnectorOperation
        {
            Id = Guid.NewGuid(),
            TenantId = tenantId,
            ConnectorInstanceId = connectorId,
            Type = PurviewConnectorOperationType.RefreshCatalog,
            Status = PurviewConnectorOperationStatus.Pending,
            ExpiresAtUtc = now.AddMinutes(10)
        };
        var store = new FakeStore(state, operation);
        var handler = new SubmitPurviewConnectorOperationHandler(store, TimeProvider.System);
        var key = Guid.NewGuid();
        while (key.Version != 4) key = Guid.NewGuid();
        var response = await handler.Handle(new SubmitPurviewConnectorOperation(
            tenantId,
            connectorId,
            "LocalWindows",
            PurviewConnectorOperationType.RefreshCatalog,
            key.ToString("D"),
            Convert.ToBase64String(state.RowVersion),
            Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D")), default);
        Check(response.OperationId == operation.Id && store.Submissions == 1,
            "A valid manual refresh was not submitted through the durable connector store.");

        var missing = await new GetPurviewConnectionHandler(new EmptyStore()).Handle(
            new GetPurviewConnectionQuery(tenantId, connectorId, "LocalWindows"), default);
        Check(missing.State == "NotConfigured" && missing.RowVersion == "*" &&
              missing.ConnectorInstanceId == connectorId,
            "Unconfigured connection status did not preserve the bootstrap connector identity and create precondition.");
        var mismatched = await new GetPurviewConnectionHandler(store).Handle(
            new GetPurviewConnectionQuery(tenantId, Guid.NewGuid(), "LocalWindows"), default);
        Check(mismatched.State == "Disconnected" &&
              mismatched.LastFailureCode == "PURVIEW_CONNECTOR_SETUP_REQUIRED" &&
              mismatched.CatalogVerificationStatus == "Unavailable" &&
              mismatched.PolicyCount == 0,
            "A recorded catalog was exposed as connected under a different installed connector identity.");
        Console.WriteLine("Purview connector durable submission, crash-window recovery, catalog reconciliation, and local status checks passed.");
    }

    private sealed class FakeStore(
        PurviewConnectorStateRecord state,
        PurviewConnectorOperation operation) : IPurviewConnectorStore
    {
        public int Submissions { get; private set; }
        public Task<PurviewConnectorStateRecord?> GetStateAsync(Guid tenantId, CancellationToken ct) =>
            Task.FromResult<PurviewConnectorStateRecord?>(state);
        public Task<PurviewConnectorOperation?> GetOperationAsync(Guid operationId, CancellationToken ct) =>
            Task.FromResult<PurviewConnectorOperation?>(operation);
        public Task<PurviewCatalogSnapshot?> GetAcceptedCatalogAsync(Guid tenantId, Guid connectorInstanceId, CancellationToken ct) =>
            Task.FromResult<PurviewCatalogSnapshot?>(null);
        public Task<PurviewConnectorSubmissionResult> SubmitAsync(PurviewConnectorSubmission submission, CancellationToken ct)
        {
            Submissions++;
            return Task.FromResult(new PurviewConnectorSubmissionResult(state, operation, false));
        }
    }

    private sealed class EmptyStore : IPurviewConnectorStore
    {
        public Task<PurviewConnectorStateRecord?> GetStateAsync(Guid tenantId, CancellationToken ct) =>
            Task.FromResult<PurviewConnectorStateRecord?>(null);
        public Task<PurviewConnectorOperation?> GetOperationAsync(Guid operationId, CancellationToken ct) =>
            Task.FromResult<PurviewConnectorOperation?>(null);
        public Task<PurviewCatalogSnapshot?> GetAcceptedCatalogAsync(Guid tenantId, Guid connectorInstanceId, CancellationToken ct) =>
            Task.FromResult<PurviewCatalogSnapshot?>(null);
        public Task<PurviewConnectorSubmissionResult> SubmitAsync(PurviewConnectorSubmission submission, CancellationToken ct) =>
            throw new NotSupportedException();
    }
}
