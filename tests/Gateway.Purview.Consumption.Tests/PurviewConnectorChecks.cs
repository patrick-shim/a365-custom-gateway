using System.Security.Cryptography;
using Gateway.Api.Infrastructure;
using Gateway.Domain.Entities;
using Gateway.Purview;
using Gateway.Purview.CatalogHost;

static class PurviewConnectorChecks
{
    public static async Task RunAsync()
    {
        static void Check(bool condition, string message)
        {
            if (!condition) throw new Exception(message);
        }

        var root = Path.Combine(Path.GetTempPath(), $"a365gw-purview-connector-{Guid.NewGuid():N}");
        var connectorDirectory = Path.Combine(root, "connector");
        var assignmentDirectory = Path.Combine(root, "assignments");
        Directory.CreateDirectory(connectorDirectory);
        Directory.CreateDirectory(assignmentDirectory);
        try
        {
            var now = DateTime.UtcNow;
            var tenantId = Guid.NewGuid();
            var connectorId = Guid.NewGuid();
            var key = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
            var executor = new FakeExecutor(tenantId);
            var compatibilityPublications = 0;
            var identity = new CatalogHostIdentity(
                tenantId,
                Guid.NewGuid(),
                connectorId,
                "example.onmicrosoft.com",
                new string('a', 40),
                true);
            var listener = new PurviewCatalogHostListener(
                identity,
                connectorDirectory,
                assignmentDirectory,
                key,
                executor,
                (_, _) =>
                {
                    compatibilityPublications++;
                    return Task.CompletedTask;
                },
                () => now,
                _ => { },
                _ => { });

            Check(!await listener.PollOnceAsync(default), "An idle listener reported provider work.");
            Check(executor.CatalogReads == 0 && executor.AssignmentWrites == 0,
                "Idle startup contacted the Purview provider.");
            var heartbeatPath = Path.Combine(connectorDirectory, $"{connectorId:D}.heartbeat.json");
            var heartbeat = PurviewConnectorProtocol.Verify<PurviewConnectorHeartbeat>(
                await File.ReadAllTextAsync(heartbeatPath), key, PurviewConnectorProtocol.HeartbeatDomain);
            PurviewConnectorProtocol.ValidateHeartbeat(heartbeat, tenantId, connectorId, now);
            foreach (var malformedEnvelope in new[]
            {
                "{\"payload\":null,\"mac\":null}",
                "{\"payload\":\" \",\"mac\":\" \"}"
            })
            {
                try
                {
                    PurviewConnectorProtocol.Verify<PurviewConnectorHeartbeat>(
                        malformedEnvelope, key, PurviewConnectorProtocol.HeartbeatDomain);
                    throw new Exception("A connector heartbeat without authentication evidence was accepted.");
                }
                catch (CryptographicException) { }
            }
            Check(PurviewConnectorProtocol.Verify<PurviewConnectorHeartbeat>(
                      await File.ReadAllTextAsync(heartbeatPath), key,
                      PurviewConnectorProtocol.HeartbeatDomain) == heartbeat,
                "A malformed heartbeat prevented later authenticated heartbeat processing.");

            // A crash after the durable Running commit but before filesystem
            // publication can leave a still-live command to be republished more
            // than five minutes later. Its authenticated absolute expiry is the
            // authority; recovery must retain the full bounded ten-minute window.
            var recoveredCommand = new PurviewConnectorCommand(
                Guid.NewGuid(), tenantId, connectorId, PurviewConnectorAction.RefreshCatalog, 1,
                new string('9', 64), now.AddMinutes(-6), now.AddMinutes(4));
            PurviewConnectorProtocol.ValidateCommand(recoveredCommand, tenantId, connectorId, now);

            var command = new PurviewConnectorCommand(
                Guid.NewGuid(), tenantId, connectorId, PurviewConnectorAction.RefreshCatalog, 1,
                new string('a', 64), now.AddSeconds(-1), now.AddMinutes(5));
            var commandPath = Path.Combine(connectorDirectory, $"{command.OperationId:D}.command.json");
            await PurviewConnectorProtocol.WriteAtomicAsync(
                commandPath,
                PurviewConnectorProtocol.Sign(command, key, PurviewConnectorProtocol.CommandDomain),
                default);
            Check(await listener.PollOnceAsync(default), "A valid refresh command was not consumed.");
            Check(executor.CatalogReads == 1 && compatibilityPublications == 1,
                "One refresh command did not produce exactly one provider read and compatibility publication.");
            var resultPath = Path.Combine(connectorDirectory, $"{command.OperationId:D}.result.json");
            var result = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                await File.ReadAllTextAsync(resultPath), key, PurviewConnectorProtocol.ResultDomain);
            PurviewConnectorProtocol.ValidateResult(result, command, tenantId, connectorId, now);
            try
            {
                PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                    "{\"payload\":null,\"mac\":null}", key, PurviewConnectorProtocol.ResultDomain);
                throw new Exception("A connector result without authentication evidence was accepted.");
            }
            catch (CryptographicException) { }
            var resultAfterMalformed = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                await File.ReadAllTextAsync(resultPath), key,
                PurviewConnectorProtocol.ResultDomain);
            Check(resultAfterMalformed.OperationId == result.OperationId &&
                  resultAfterMalformed.Status == result.Status &&
                  resultAfterMalformed.CatalogHash == result.CatalogHash,
                "A malformed result prevented later authenticated result processing.");
            Check(result.Status == "Succeeded" && result.Catalog is not null,
                "Refresh result did not carry authenticated catalog evidence.");
            var acceptedCatalog = result.Catalog ?? throw new Exception("Refresh catalog evidence was missing.");
            var staleCatalog = acceptedCatalog with
            {
                RetrievedAtUtc = new DateTimeOffset(result.CompletedAtUtc)
                    .Subtract(PurviewPolicyCatalogValidation.MaximumConnectorResultAge)
                    .AddSeconds(-1)
            };
            var staleResult = result with
            {
                Catalog = staleCatalog,
                CatalogHash = PurviewConnectorProtocol.Digest(staleCatalog)
            };
            try
            {
                PurviewConnectorProtocol.ValidateResult(staleResult, command, tenantId, connectorId, now);
                throw new Exception("A newly completed connector result accepted stale catalog evidence.");
            }
            catch (InvalidOperationException) { }
            Check(!await listener.PollOnceAsync(default) && executor.CatalogReads == 1,
                "A completed refresh command was executed more than once.");
            var checkpointPath = Path.Combine(connectorDirectory, $"{connectorId:D}.checkpoint.json");
            var checkpoint = PurviewConnectorProtocol.Verify<PurviewConnectorCheckpoint>(
                await File.ReadAllTextAsync(checkpointPath), key, PurviewConnectorProtocol.CheckpointDomain);
            PurviewConnectorProtocol.ValidateCheckpoint(checkpoint, tenantId, connectorId, now);
            Check(checkpoint.HighestCompletedGeneration == 1,
                "Refresh completion did not advance the authenticated generation checkpoint.");

            // Simulate cleanup after durable API acceptance, then restart the
            // listener. The checkpoint must still stop an old generation before
            // another provider read.
            File.Delete(commandPath);
            File.Delete(resultPath);
            listener = new PurviewCatalogHostListener(
                identity,
                connectorDirectory,
                assignmentDirectory,
                key,
                executor,
                (_, _) =>
                {
                    compatibilityPublications++;
                    return Task.CompletedTask;
                },
                () => now,
                _ => { },
                _ => { });

            var replay = command with
            {
                OperationId = Guid.NewGuid(),
                RequestHash = new string('b', 64)
            };
            var replayCommandPath = Path.Combine(connectorDirectory, $"{replay.OperationId:D}.command.json");
            await PurviewConnectorProtocol.WriteAtomicAsync(
                replayCommandPath,
                PurviewConnectorProtocol.Sign(replay, key, PurviewConnectorProtocol.CommandDomain),
                default);
            Check(await listener.PollOnceAsync(default), "A replayed generation was not terminated.");
            var replayResult = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                await File.ReadAllTextAsync(Path.Combine(connectorDirectory, $"{replay.OperationId:D}.result.json")),
                key,
                PurviewConnectorProtocol.ResultDomain);
            Check(replayResult.Status == "NeedsAttention" &&
                  replayResult.FailureCode == "PURVIEW_CONNECTOR_GENERATION_REPLAY" &&
                  executor.CatalogReads == 1,
                "A replayed generation reached the provider after accepted transport cleanup or was mislabeled.");

            var slowCommand = new PurviewConnectorCommand(
                Guid.NewGuid(), tenantId, connectorId, PurviewConnectorAction.VerifyConnection, 2,
                new string('f', 64), now.AddSeconds(-1), now.AddSeconds(10));
            var slowCommandPath = Path.Combine(connectorDirectory, $"{slowCommand.OperationId:D}.command.json");
            executor.AfterCatalogRead = () => now = now.AddSeconds(11);
            await PurviewConnectorProtocol.WriteAtomicAsync(
                slowCommandPath,
                PurviewConnectorProtocol.Sign(slowCommand, key, PurviewConnectorProtocol.CommandDomain),
                default);
            Check(await listener.PollOnceAsync(default), "A completed-after-deadline read was not terminated.");
            executor.AfterCatalogRead = null;
            var slowResult = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                await File.ReadAllTextAsync(Path.Combine(connectorDirectory, $"{slowCommand.OperationId:D}.result.json")),
                key,
                PurviewConnectorProtocol.ResultDomain);
            Check(slowResult.Status == "TimedOut" && slowResult.Catalog is null &&
                  slowResult.FailureCode == "PURVIEW_CONNECTOR_OPERATION_TIMED_OUT" &&
                  executor.CatalogReads == 2 && compatibilityPublications == 1,
                "A provider read completing after its deadline published a successful catalog.");

            var invalidPath = Path.Combine(connectorDirectory, $"{Guid.NewGuid():D}.command.json");
            await File.WriteAllTextAsync(invalidPath, "not-authenticated");
            Check(!await listener.PollOnceAsync(default) && executor.CatalogReads == 2,
                "An unauthenticated command reached the provider.");
            File.Delete(invalidPath);

            var assignment = new PolicyAssignmentRequest(
                Guid.NewGuid(), tenantId, Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(),
                new string('c', 64), DateTime.UtcNow.AddMinutes(5));
            await PolicyAssignmentProtocol.WriteAtomicAsync(
                Path.Combine(assignmentDirectory, $"{assignment.OperationId:D}.request.json"),
                PolicyAssignmentProtocol.Sign(assignment, key, "request"),
                default);
            Check(await listener.PollOnceAsync(default), "A valid assignment command was not consumed.");
            Check(executor.AssignmentWrites == 1 && executor.CatalogReads == 2 && compatibilityPublications == 1,
                "Assignment processing performed an implicit full catalog refresh.");
            var assignmentResult = PolicyAssignmentProtocol.Verify<PolicyAssignmentResult>(
                await File.ReadAllTextAsync(Path.Combine(assignmentDirectory, $"{assignment.OperationId:D}.result.json")),
                key,
                "result");
            PolicyAssignmentProtocol.Validate(assignmentResult, assignment, now);
            Check(assignmentResult.Assigned && assignmentResult.PolicyId == assignment.PolicyId &&
                  assignmentResult.Revision == new string('e', 64) &&
                  assignmentResult.DefinitionRevision == new string('f', 64),
                "Assignment result was not bound to the selected policy.");
            foreach (var invalidAssignmentResult in new[]
            {
                assignmentResult with { Revision = null },
                assignmentResult with { DefinitionRevision = null },
                assignmentResult with { DefinitionRevision = new string('A', 64) },
                assignmentResult with { ReadAtUtc = assignment.ExpiresAtUtc.AddSeconds(1) }
            })
            {
                try
                {
                    PolicyAssignmentProtocol.Validate(invalidAssignmentResult, assignment, now);
                    throw new Exception("An assignment result with incomplete or late evidence was accepted.");
                }
                catch (InvalidOperationException) { }
            }

            var legacySuccess = new
            {
                assignmentResult.OperationId,
                assignmentResult.TenantId,
                assignmentResult.AgentIdentityId,
                assignmentResult.PolicyId,
                assignmentResult.RequestDigest,
                Assigned = true,
                Revision = new string('e', 64),
                FailureCode = (string?)null,
                ReadAtUtc = now
            };
            var legacyRow = new AgentPolicyAssignment
            {
                Id = assignment.OperationId,
                Status = "Pending",
                ConfirmedAtUtc = now.AddSeconds(-1)
            };
            var laterRequest = assignment with { OperationId = Guid.NewGuid() };
            var laterResult = assignmentResult with
            {
                OperationId = laterRequest.OperationId,
                RequestDigest = PolicyAssignmentProtocol.Digest(laterRequest)
            };
            var malformedRequest = assignment with { OperationId = Guid.NewGuid() };
            var malformedRow = new AgentPolicyAssignment
            {
                Id = malformedRequest.OperationId,
                Status = "Pending",
                ConfirmedAtUtc = now.AddSeconds(-1)
            };
            var laterRow = new AgentPolicyAssignment
            {
                Id = laterRequest.OperationId,
                Status = "Pending",
                ConfirmedAtUtc = now.AddSeconds(-1)
            };
            var queue = new[]
            {
                (Row: legacyRow, Request: assignment,
                    Envelope: PolicyAssignmentProtocol.Sign(legacySuccess, key, "result")),
                (Row: malformedRow, Request: malformedRequest,
                    Envelope: "{\"payload\":null,\"mac\":null}"),
                (Row: laterRow, Request: laterRequest,
                    Envelope: PolicyAssignmentProtocol.Sign(laterResult, key, "result"))
            };
            var outcomes = queue.Select(item => AgentPolicyAssignmentWorker.TryApplyAssignmentResult(
                item.Row,
                item.Request,
                item.Envelope,
                key,
                now)).ToArray();
            Check(!outcomes[0] && legacyRow.Status == "Failed" &&
                  legacyRow.FailureCode == "ASSIGNMENT_RESULT_INVALID" &&
                  !outcomes[1] && malformedRow.Status == "Failed" &&
                  malformedRow.FailureCode == "ASSIGNMENT_RESULT_INVALID" &&
                  outcomes[2] && laterRow.Status == "Assigned" &&
                  laterRow.AssignedRevision == laterResult.DefinitionRevision,
                "An invalid assignment result poisoned the queue or allowed an unconfirmed success.");

            var oversizedRequest = assignment with { OperationId = Guid.NewGuid() };
            var oversizedRow = new AgentPolicyAssignment
            {
                Id = oversizedRequest.OperationId,
                Status = "Pending",
                ConfirmedAtUtc = now.AddSeconds(-1)
            };
            var oversizedPath = Path.Combine(
                assignmentDirectory, $"{oversizedRequest.OperationId:D}.oversized.result.json");
            await File.WriteAllTextAsync(oversizedPath, new string('x', 32_769));
            var validFileRequest = assignment with { OperationId = Guid.NewGuid() };
            var validFileResult = assignmentResult with
            {
                OperationId = validFileRequest.OperationId,
                RequestDigest = PolicyAssignmentProtocol.Digest(validFileRequest)
            };
            var validFileRow = new AgentPolicyAssignment
            {
                Id = validFileRequest.OperationId,
                Status = "Pending",
                ConfirmedAtUtc = now.AddSeconds(-1)
            };
            var validFilePath = Path.Combine(
                assignmentDirectory, $"{validFileRequest.OperationId:D}.valid.result.json");
            await PolicyAssignmentProtocol.WriteAtomicAsync(
                validFilePath,
                PolicyAssignmentProtocol.Sign(validFileResult, key, "result"),
                default);
            var oversizedAccepted = await AgentPolicyAssignmentWorker.TryApplyAssignmentResultFileAsync(
                oversizedRow, oversizedRequest, oversizedPath, key, now, default);
            var validFileAccepted = await AgentPolicyAssignmentWorker.TryApplyAssignmentResultFileAsync(
                validFileRow, validFileRequest, validFilePath, key, now, default);
            Check(!oversizedAccepted && oversizedRow.Status == "Failed" &&
                  oversizedRow.FailureCode == "ASSIGNMENT_RESULT_INVALID" && File.Exists(oversizedPath) &&
                  validFileAccepted && validFileRow.Status == "Assigned" &&
                  validFileRow.AssignedRevision == validFileResult.DefinitionRevision,
                "An oversized assignment result poisoned the file queue or removed provider evidence.");

            try
            {
                PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                    await File.ReadAllTextAsync(replayCommandPath),
                    key,
                    PurviewConnectorProtocol.ResultDomain);
                throw new Exception("Connector command crossed authentication domains.");
            }
            catch (CryptographicException) { }
            try
            {
                PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                    await File.ReadAllTextAsync(replayCommandPath),
                    Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)),
                    PurviewConnectorProtocol.CommandDomain);
                throw new Exception("Wrong connector key was accepted.");
            }
            catch (CryptographicException) { }

            Console.WriteLine("Purview connector idle, authenticated refresh, replay, deduplication, heartbeat, and assignment-isolation checks passed.");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FakeExecutor(Guid tenantId) : IPurviewCatalogHostExecutor
    {
        public int CatalogReads { get; private set; }
        public int AssignmentWrites { get; private set; }
        public Action? AfterCatalogRead { get; set; }

        public Task<PurviewPolicyCatalog> ReadCatalogAsync(
            PurviewConnectorAction action,
            CancellationToken cancellationToken)
        {
            CatalogReads++;
            AfterCatalogRead?.Invoke();
            var applicationId = Guid.NewGuid();
            return Task.FromResult(new PurviewPolicyCatalog(
                tenantId,
                DateTimeOffset.UtcNow,
                [new PurviewExistingPolicy(
                    Guid.NewGuid(),
                    "Existing policy",
                    "Enable",
                    ["Application"],
                    [applicationId],
                    true,
                    new string('d', 64),
                    new string('c', 64),
                    [applicationId])]));
        }

        public Task<CatalogHostAssignmentRead> ApplyAssignmentAsync(
            PolicyAssignmentRequest request,
            CancellationToken cancellationToken)
        {
            AssignmentWrites++;
            return Task.FromResult(new CatalogHostAssignmentRead(
                true,
                new string('e', 64),
                new string('f', 64),
                null));
        }
    }
}
