using System.Net;
using System.Text.Json;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;

namespace Gateway.AdminUi.BrowserHost;

internal static class FixtureSelfTest
{
    public static async Task<int> RunAsync()
    {
        var checks = 0;
        void Check(bool condition, string description)
        {
            if (!condition) throw new InvalidOperationException($"Fixture self-test failed: {description}");
            checks++;
        }
        async Task<TException> Throws<TException>(Func<Task> action) where TException : Exception
        {
            try { await action(); }
            catch (TException exception) { checks++; return exception; }
            throw new InvalidOperationException($"Fixture self-test expected {typeof(TException).Name}.");
        }
        static (FixtureState State, IGatewayApiClient Api) Create(string scenario, string role = "Administrator")
        {
            var state = new FixtureState(new(Scenario: scenario, Role: role, MutationDelayMs: 0));
            return (state, FixtureGatewayApi.Create(state));
        }
        static RegisterAgentRequest Registration(string externalId = "browser-created-agent", bool reuse = false) => new(
            externalId, "Browser-created synthetic agent", null, FixtureIdentity.ActorId.ToString("D"),
            "Development", null, new AgentBlueprintSelectionDto(reuse ? "UseExisting" : "CreateNew",
                reuse ? FixtureState.BlueprintId.ToString("D") : null, reuse ? null : "New synthetic blueprint"));

        try
        {
            var fleet = Create("fleet");
            var first = await fleet.Api.GetAgentsAsync(new(Limit: 100));
            var second = await fleet.Api.GetAgentsAsync(new(Limit: 100, Cursor: first.NextCursor));
            var third = await fleet.Api.GetAgentsAsync(new(Limit: 100, Cursor: second.NextCursor));
            Check(first.TotalCount == 237 && first.Items.Count == 100 && first.NextCursor is not null, "237-row first page");
            Check(second.TotalCount == 237 && second.Items.Count == 100 && second.NextCursor is not null, "second full page");
            Check(third.TotalCount == 237 && third.Items.Count == 37 && third.NextCursor is null, "final 37-row page");
            var all = first.Items.Concat(second.Items).Concat(third.Items).ToArray();
            Check(all.Select(item => item.AgentId).Distinct().Count() == 237, "no overlapping pages");
            Check(all.Select(item => item.AgentId).SequenceEqual(Enumerable.Range(1, 237).Select(FixtureState.SeedAgentId)),
                "ascending creation time and SQL GUID ordering do not use insertion or .NET GUID order");
            Check(first.Items[0].CreatedAtUtc == first.Items[2].CreatedAtUtc &&
                first.Items[^1].CreatedAtUtc == second.Items[0].CreatedAtUtc, "timestamp ties include a page boundary");
            Check(first.NextCursor?.Length == 34 &&
                ListAgentsCursor.TryDecode(first.NextCursor, out var cursorTime, out var cursorId) &&
                cursorTime == first.Items[^1].CreatedAtUtc && cursorId == first.Items[^1].AgentId,
                "fixture emits the unmodified production cursor contract");
            var repeated = await fleet.Api.GetAgentsAsync(new(Limit: 100, Cursor: first.NextCursor));
            Check(repeated.Items.Select(item => item.AgentId).SequenceEqual(second.Items.Select(item => item.AgentId)),
                "exact cursor replay returns the same stable page");
            var filter = new AgentListQuery(Status: " active ", Environment: " development ", Search: " INVOICE-EU ", Limit: 100);
            var filteredFirst = await fleet.Api.GetAgentsAsync(filter);
            var filteredLast = await fleet.Api.GetAgentsAsync(filter with { Cursor = filteredFirst.NextCursor });
            Check(filteredFirst.TotalCount == 137 && filteredFirst.Items.Count == 100 &&
                filteredLast.TotalCount == 137 && filteredLast.Items.Count == 37 && filteredLast.NextCursor is null,
                "trimmed case-insensitive combined filters produce 137 complete matches");
            Check(filteredFirst.Items.Concat(filteredLast.Items).Select(item => item.AgentId).Distinct().Count() == 137,
                "combined filters remain stable across pages");
            Check(filteredFirst.Items[0].Name.Contains("invoice-eu", StringComparison.OrdinalIgnoreCase) &&
                !filteredFirst.Items[0].ExternalAgentId.Contains("invoice-eu", StringComparison.OrdinalIgnoreCase) &&
                !filteredFirst.Items[1].Name.Contains("invoice-eu", StringComparison.OrdinalIgnoreCase) &&
                filteredFirst.Items[1].ExternalAgentId.Contains("invoice-eu", StringComparison.OrdinalIgnoreCase),
                "search includes distinct name-only and external-ID-only matches");
            var fullFinal = await fleet.Api.GetAgentsAsync(new(Search: "Auxiliary", Limit: 100));
            Check(fullFinal.TotalCount == 100 && fullFinal.Items.Count == 100 && fullFinal.NextCursor is null,
                "a full final page does not advertise a next cursor");
            var byName = await fleet.Api.GetAgentsAsync(new(Search: "SYNTHETIC AGENT 137"));
            var byExternalId = await fleet.Api.GetAgentsAsync(new(Search: "FIXTURE-AGENT-137"));
            Check(byName.TotalCount == 1 && byExternalId.Items.Single().AgentId == byName.Items.Single().AgentId, "search covers name and external ID beyond page one");
            var active = await fleet.Api.GetAgentsAsync(new(Status: "Active", Limit: 1));
            Check(active.TotalCount == 177 && active.Items.Count == 1, "filtered count is independent of page size");
            var actionRequiredCount = 0;
            foreach (var status in new[] { "AwaitingAdminApproval", "Failed", "RequiresManualIntervention" })
            {
                var preview = await fleet.Api.GetAgentsAsync(new(Status: status, Limit: 8));
                Check(preview.TotalCount == 10 && preview.Items.Count == 8 && preview.NextCursor is not null, "overview previews are not whole-status totals");
                actionRequiredCount += preview.TotalCount!.Value;
            }
            Check(actionRequiredCount == 30, "overview action-required total is 30 rather than the 24 preview rows");
            var malformed = await Throws<GatewayApiException>(() => fleet.Api.GetAgentsAsync(new(Cursor: "not-a-cursor")));
            Check(malformed.StatusCode == HttpStatusCode.BadRequest && malformed.ValidationErrors.ContainsKey("Cursor"),
                "malformed cursor enables safe Restart list");
            var payload = Convert.FromBase64String(first.NextCursor!.Replace('-', '+').Replace('_', '/') + "==");
            payload[0] = 255;
            var unknownVersion = Convert.ToBase64String(payload).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            var unknownCursor = await Throws<GatewayApiException>(() => fleet.Api.GetAgentsAsync(new(Cursor: unknownVersion)));
            Check(unknownCursor.StatusCode == HttpStatusCode.BadRequest && unknownCursor.ValidationErrors.ContainsKey("Cursor"),
                "unknown cursor versions use the same field validation shape");
            var expiredCursor = Create("cursor-error");
            var beforeError = await expiredCursor.Api.GetAgentsAsync(filter);
            var cursorError = await Throws<GatewayApiException>(() =>
                expiredCursor.Api.GetAgentsAsync(filter with { Cursor = beforeError.NextCursor }));
            Check(cursorError.ValidationErrors.ContainsKey("Cursor"), "cursor-error scenario rejects continuation rather than the first page");
            var restarted = await expiredCursor.Api.GetAgentsAsync(filter);
            Check(restarted.TotalCount == 137 &&
                restarted.Items.Select(item => item.AgentId).SequenceEqual(beforeError.Items.Select(item => item.AgentId)),
                "restart preserves the applied filters and first page");
            Check((await Create("unknown-total").Api.GetAgentsAsync()).TotalCount is null, "unknown totals remain unknown");

            foreach (var role in FixtureIdentity.Roles)
            {
                var item = Create("operation-manual", role);
                var identity = FixtureIdentity.Create(role);
                Check(identity.IsInRole($"Gateway.{role}") && identity.FindFirst("oid")?.Value == FixtureIdentity.ActorId.ToString("D"),
                    $"new synthetic identity for {role}");
                Check((await item.Api.GetAgentsAsync()).TotalCount == 1, $"{role} can read inventory");
                var id = FixtureState.Id(3, 1);
                if (role == "Administrator")
                {
                    await item.Api.GetSystemConfigAsync();
                    await item.Api.GetAgentIngressCredentialsAsync(id);
                    checks += 2;
                }
                else
                {
                    var denied = await Throws<GatewayApiException>(() => item.Api.RegisterAgentAsync(Registration()));
                    Check(denied.StatusCode == HttpStatusCode.Forbidden, $"{role} cannot register");
                    await Throws<GatewayApiException>(() => item.Api.GetAgentIngressCredentialsAsync(id));
                    await Throws<GatewayApiException>(() => item.Api.GetSystemConfigAsync());
                }
                if (role is "Administrator" or "Operator")
                {
                    await item.Api.GetProvisioningHistoryAsync(id);
                    checks++;
                }
                else await Throws<GatewayApiException>(() => item.Api.GetOperationStatusAsync(FixtureState.Id(4, 1)));
                if (role != "Administrator")
                {
                    var denied = await Throws<GatewayApiException>(() =>
                        item.Api.CompleteAgent365RegistrationAsync(FixtureState.Id(4, 1)));
                    Check(denied.StatusCode == HttpStatusCode.Forbidden, $"{role} cannot complete Registry registration");
                }
                if (role is "Administrator" or "Auditor")
                {
                    await item.Api.GetAgentAuditEventsAsync(id);
                    checks++;
                }
                else await Throws<GatewayApiException>(() => item.Api.GetAgentAuditEventsAsync(id));
            }

            Check((await Create("blueprints-empty").Api.GetAgentIdentityBlueprintsAsync()).Items.Count == 0, "empty blueprint inventory");
            Check((await Create("blueprints-rejected").Api.GetAgentIdentityBlueprintsAsync()).Items.All(item => !item.IsAgent365Compatible), "rejected blueprint inventory");
            Check((await Create("blueprints-mixed").Api.GetAgentIdentityBlueprintsAsync()).Items.Count == 2, "mixed blueprint inventory");
            await Throws<GatewayApiException>(() => Create("blueprints-rejected").Api.RegisterAgentAsync(Registration(reuse: true)));
            var defaults = Create("defaults");
            var registered = await defaults.Api.RegisterAgentAsync(Registration(reuse: true));
            Check(registered.GatewayCredential?.ApiKey.StartsWith("invalid-browser-fixture-key-", StringComparison.Ordinal) == true, "one-time invalid key in response");
            var details = (await defaults.Api.GetAgentAsync(registered.AgentId)).Value;
            var registeredOperation = await defaults.Api.GetOperationStatusAsync(registered.OperationId);
            Check(registeredOperation.AgentId == details.AgentId &&
                registeredOperation.OperationId == registered.OperationId &&
                registered.ExternalAgentId == details.ExternalAgentId, "registration, operation and context share exact identities");
            Check(details.Features is { Agent365ObservabilityEnabled: true, AzureMonitorExportEnabled: true, PurviewEnabled: false }, "defaults remain independent of optional protection");
            Check(!JsonSerializer.Serialize(defaults.State.Snapshot()).Contains("invalid-browser-fixture-key-", StringComparison.Ordinal), "state/counters do not retain raw key");
            Check(!JsonSerializer.Serialize(await defaults.Api.GetAgentIngressCredentialsAsync(registered.AgentId)).Contains("ApiKey", StringComparison.OrdinalIgnoreCase), "credential readback is metadata-only");
            await Throws<GatewayApiException>(() => defaults.Api.RegisterAgentAsync(Registration()));
            Check((await defaults.Api.GetAgentsAsync()).TotalCount == 1, "duplicate registration cannot create a second agent");
            var unknownRegistration = Create("registration-unknown");
            await Throws<GatewayApiTransportException>(() => unknownRegistration.Api.RegisterAgentAsync(Registration()));
            Check((await unknownRegistration.Api.GetAgentsAsync(new(Search: "browser-created-agent"))).Items
                    .Single().ExternalAgentId == "browser-created-agent",
                "interrupted create persists a discoverable registration");
            Check((await Create("registration-no-key").Api.RegisterAgentAsync(Registration())).GatewayCredential is null, "accepted missing-key scenario");
            await Throws<GatewayApiException>(() => Create("registration-validation").Api.RegisterAgentAsync(Registration()));
            await Throws<GatewayApiException>(() => Create("admission-closed").Api.RegisterAgentAsync(Registration()));

            var agentId = FixtureState.Id(3, 1);
            var lifecycle = Create("fleet");
            var oldKey = (await lifecycle.Api.GetAgentIngressCredentialsAsync(agentId)).Items.Single();
            await Throws<GatewayApiException>(() => lifecycle.Api.RevokeAgentIngressCredentialAsync(agentId, oldKey.KeyId));
            var replacement = await lifecycle.Api.IssueAgentIngressCredentialAsync(agentId);
            Check(replacement.GatewayCredential.KeyId != oldKey.KeyId, "replacement has a new key identity");
            await lifecycle.Api.RevokeAgentIngressCredentialAsync(agentId, oldKey.KeyId);
            var keys = await lifecycle.Api.GetAgentIngressCredentialsAsync(agentId);
            Check(keys.Items.Count(item => item.RevokedAtUtc is null) == 1 && keys.Items.Count == 2, "revocation preserves the replacement");
            Check((await lifecycle.Api.DisableAgentAsync(agentId)).Status == "Disabled", "disable readback");
            Check((await lifecycle.Api.EnableAgentAsync(agentId)).Status == "Active", "enable readback");
            Check((await lifecycle.Api.GetAgentAuditEventsAsync(agentId)).Items.Count == 5, "safe audit events track lifecycle actions");
            var lostKey = Create("credential-unknown");
            await Throws<GatewayApiTransportException>(() => lostKey.Api.IssueAgentIngressCredentialAsync(agentId));
            Check((await lostKey.Api.GetAgentIngressCredentialsAsync(agentId)).Items.Count == 2, "unknown issuance requires metadata readback");
            var unknownDisable = Create("lifecycle-unknown");
            await Throws<GatewayApiTransportException>(() => unknownDisable.Api.DisableAgentAsync(agentId));
            Check((await unknownDisable.Api.GetAgentAsync(agentId)).Value.Status == "Disabled", "unknown lifecycle mutation persists truthfully");

            var operationId = FixtureState.Id(4, 1);
            var handoff = new RegistrationHandoffState();
            Check(!handoff.TryConsumeAutomaticCompletion(operationId, agentId), "direct entry has no saved-key permit");
            handoff.RecordSavedCredential(operationId, agentId);
            Check(!handoff.TryConsumeAutomaticCompletion(FixtureState.Id(4, 2), agentId), "saved-key permit is bound to operation");
            Check(!handoff.TryConsumeAutomaticCompletion(operationId, FixtureState.Id(3, 2)), "saved-key permit is bound to agent");
            Check(handoff.TryConsumeAutomaticCompletion(operationId, agentId), "exact saved-key permit can be consumed");
            Check(!handoff.TryConsumeAutomaticCompletion(operationId, agentId), "saved-key permit is one-use");
            var manual = Create("operation-manual");
            Check((await manual.Api.GetOperationStatusAsync(operationId)).Agent365RegistrationCompletionAvailable, "manual completion is advertised");
            var completion = await manual.Api.CompleteAgent365RegistrationAsync(operationId);
            Check(completion.OperationId == operationId && completion.AgentId == agentId &&
                !string.IsNullOrWhiteSpace(completion.Agent365RegistrationId), "completion response is bound and includes Registry identity");
            Check((await manual.Api.GetOperationStatusAsync(operationId)).Status == "Completed" &&
                (await manual.Api.GetAgentAsync(agentId)).Value.Status == "Active", "completion and final registration state");
            foreach (var name in new[] { "operation-consent", "operation-claims" })
            {
                var item = Create(name);
                var challenge = await Throws<GatewayApiException>(() => item.Api.CompleteAgent365RegistrationAsync(operationId));
                Check(challenge.RequiresUserInteraction && challenge.HasClaimsChallenge == (name == "operation-claims"),
                    "separate consent and claims challenge shapes");
                Check((await item.Api.GetOperationStatusAsync(operationId)).Status == "AwaitingAdministratorAction", "challenge does not pretend completion");
            }
            var unknownOperation = Create("operation-unknown");
            await Throws<GatewayApiTransportException>(() => unknownOperation.Api.CompleteAgent365RegistrationAsync(operationId));
            var readback = await unknownOperation.Api.GetOperationStatusAsync(operationId);
            Check(readback is { Status: "RequiresManualIntervention", CurrentStep: "RegisterAgent", ReplaySupported: false,
                Agent365RegistrationCompletionAvailable: false }, "unknown Registry result remains non-replayable");
            var committed = Create("operation-unknown-committed");
            await Throws<GatewayApiTransportException>(() => committed.Api.CompleteAgent365RegistrationAsync(operationId));
            Check((await committed.Api.GetOperationStatusAsync(operationId)).Status == "Completed", "committed unknown outcome recoverable by readback");
            var verifying = Create("operation-verifying");
            await verifying.Api.CompleteAgent365RegistrationAsync(operationId);
            Check((await verifying.Api.GetOperationStatusAsync(operationId)).Status == "Running", "accepted is not final completion");
            verifying.State.SetOperation(new("Completed", operationId));
            Check((await verifying.Api.GetAgentAsync(agentId)).Value.Status == "Active", "control can advance final verification");
            await Throws<GatewayApiException>(() => Create("operation-unavailable").Api.CompleteAgent365RegistrationAsync(operationId));
            await Throws<GatewayApiException>(() => Create("operation-legacy").Api.CompleteAgent365RegistrationAsync(operationId));

            var failing = Create("read-error");
            await Throws<GatewayApiException>(() => failing.Api.GetAgentsAsync());
            failing.State.SetReadErrors(new([]));
            Check((await failing.Api.GetAgentsAsync()).TotalCount == 237, "read recovery without resetting identity/data");
            var oldApi = failing.Api;
            failing.State.Reset(new("empty", "SupportReader", 0));
            await Throws<UnexpectedFixtureCallException>(() => oldApi.GetAgentsAsync());
            Check((await FixtureGatewayApi.Create(failing.State).GetAgentsAsync()).TotalCount == 0, "reset rejects stale circuits");
            await Throws<UnexpectedFixtureCallException>(() => fleet.Api.GetPurviewRuntimeTestAsync(operationId));
            var guards = new IsolationGuards();
            using (var client = new HttpClient(new DenyNetworkHandler(guards)))
                await Throws<UnexpectedFixtureCallException>(() => client.GetAsync("https://provider.browser-fixture.invalid/"));
            await Throws<UnexpectedFixtureCallException>(() => Task.FromResult(new DenyClientFactory(guards).CreateClient("unexpected")));
            await Throws<UnexpectedFixtureCallException>(() => new DenyAccessTokenProvider(guards).GetAccessTokenAsync());
            await Throws<UnexpectedFixtureCallException>(() => new DenyRuntimeExecution(guards).ExecuteAsync(
                FixtureIdentity.Create("Administrator"), Guid.Empty, null!, default));
            var core = Create("m4-core");
            Check((await core.Api.GetProtectionCapabilitiesAsync()).Value.Items.All(item => item.Status == "NotInstalled"),
                "M4 core-only capability facts are explicit");
            foreach (var mode in new[] { "m4-ready", "m4-simulation", "m4-off", "m4-expired" })
            {
                var item = Create(mode);
                var profile = (await item.Api.GetPurviewDlpProfilesAsync()).Value.Items.Single();
                var agent = (await item.Api.GetAgentsAsync()).Items.Single();
                Check(agent.Features?.PurviewPolicyMode == profile.PolicyMode &&
                    agent.Features?.PurviewReadiness == profile.Readiness, "M4 surfaces share exact fixture state");
                Check(profile.Readiness.ValidUntilUtc is not null, "M4 fixture bounds cached readiness");
            }
            var connection = Create("m4-connection");
            var reviewed = await connection.Api.ReviewPurviewTenantConnectionAsync(new(FixtureIdentity.TenantId, "*"));
            var confirmed = await connection.Api.ConfirmProtectionOperationReviewAsync(reviewed.Value);
            var acceptedConnection = await connection.Api.StartPurviewTenantConnectionOperationAsync(confirmed.Value, Guid.NewGuid(), "*");
            Check(acceptedConnection.Value.OperationId == reviewed.Value.ReviewTokenId, "M4 connection keeps reviewed operation identity");
            var reopened = await connection.Api.GetProtectionAdminOperationAsync(acceptedConnection.Value.OperationId);
            Check(reopened.Value.CompanionLaunch?.OperationId == acceptedConnection.Value.OperationId,
                "M4 operation readback returns the same accepted companion launch");
            Check((await connection.Api.GetPurviewTenantConnectionAsync()).Value.Connection?.Status == "AwaitingAdministrator",
                "M4 accepted launch is not verified connection");
            var launch = reopened.Value.CompanionLaunch ?? throw new InvalidOperationException("Expected the owned synthetic launch.");
            var connectionState = (await connection.Api.GetPurviewTenantConnectionAsync()).Value.Connection
                ?? throw new InvalidOperationException("Expected the synthetic connection.");
            var evidence = new PurviewTenantConnectionEvidenceDto(FixtureIdentity.TenantId, FixtureIdentity.ActorId,
                ["DlpPolicy.ReadWrite", "DlpRule.ReadWrite", "KnowYourData.ReadWrite", "SensitiveInformationTypes.Read"],
                DateTimeOffset.UtcNow, launch.ExpiresAtUtc,
                [new(Guid.Parse("11111111-1111-4111-8111-111111111104"), "Synthetic employee identifier", "Fixture")]);
            var completionReview = await connection.Api.ReviewPurviewTenantConnectionCompletionAsync(
                launch.OperationId, launch.InventoryGenerationId, evidence, connectionState.RowVersion);
            Check(completionReview.Value.ReviewTokenId != launch.OperationId,
                "M4 completion authorization is distinct from the connection operation");
            var completionConfirmation = await connection.Api.ConfirmProtectionOperationReviewAsync(completionReview.Value);
            var completionAccepted = await connection.Api.CompletePurviewTenantConnectionOperationAsync(
                launch.OperationId, evidence, completionConfirmation.Value, Guid.NewGuid(), connectionState.RowVersion);
            Check(completionAccepted.Value.OperationId == launch.OperationId,
                "M4 completion resumes and returns the original connection operation");
            var authorization = (await connection.Api.GetProtectionAdminOperationAsync(completionReview.Value.ReviewTokenId)).Value;
            Check(authorization.Operation.Status == "Submitted" && authorization.Operation.ReadbackReferenceId == launch.OperationId &&
                authorization.CompanionLaunch is null, "M4 submitted authorization points to the original operation without a launch");
            var continued = (await connection.Api.GetProtectionAdminOperationAsync(launch.OperationId)).Value;
            Check(continued.Operation.Type == "ConnectPurviewTenant" && continued.Operation.Status == "Pending" &&
                continued.CompanionLaunch is null, "M4 continued verification never returns stale launch instructions");
            Check((await connection.Api.GetPurviewTenantConnectionAsync()).Value.Connection?.Status == "PendingVerification",
                "M4 completion acceptance is not independent provider verification");
            connection.State.AdvanceProtection(new("connection-verified"));
            Check((await connection.Api.GetPurviewTenantConnectionAsync()).Value.Connection?.Status == "Connected",
                "M4 connection verification is a separate controlled step");
            var connectionResult = (await connection.Api.GetProtectionAdminOperationAsync(launch.OperationId)).Value.Operation;
            Check(connectionResult.Status == "Completed" && connectionResult.Steps.Count(step => step.Status == "Skipped") == 4 &&
                connectionResult.Steps.Single(step => step.Step == "ValidateRuntimeVerdict").Status == "Skipped" &&
                connectionResult.Steps.Select(step => step.OrderIndex).SequenceEqual(Enumerable.Range(0, 8)),
                "M4 completed connection explicitly records separate unrun policy and runtime checks");
            var failedConnection = Create("m4-connection");
            var failedReview = await failedConnection.Api.ReviewPurviewTenantConnectionAsync(new(FixtureIdentity.TenantId, "*"));
            var failedConfirmation = await failedConnection.Api.ConfirmProtectionOperationReviewAsync(failedReview.Value);
            var failedStart = await failedConnection.Api.StartPurviewTenantConnectionOperationAsync(failedConfirmation.Value, Guid.NewGuid(), "*");
            var failedLaunch = (await failedConnection.Api.GetProtectionAdminOperationAsync(failedStart.Value.OperationId)).Value.CompanionLaunch
                ?? throw new InvalidOperationException("Expected the failure fixture's synthetic launch.");
            var failedResource = (await failedConnection.Api.GetPurviewTenantConnectionAsync()).Value.Connection
                ?? throw new InvalidOperationException("Expected the failure fixture's connection.");
            var failedEvidence = evidence with
            {
                ObservedAtUtc = DateTimeOffset.UtcNow, InventoryExpiresAtUtc = failedLaunch.ExpiresAtUtc
            };
            var failedCompletion = await failedConnection.Api.ReviewPurviewTenantConnectionCompletionAsync(
                failedLaunch.OperationId, failedLaunch.InventoryGenerationId, failedEvidence, failedResource.RowVersion);
            var failedCompletionConfirmation = await failedConnection.Api.ConfirmProtectionOperationReviewAsync(failedCompletion.Value);
            await failedConnection.Api.CompletePurviewTenantConnectionOperationAsync(
                failedLaunch.OperationId, failedEvidence, failedCompletionConfirmation.Value, Guid.NewGuid(), failedResource.RowVersion);
            failedConnection.State.AdvanceProtection(new("connection-failed"));
            var failedOperation = (await failedConnection.Api.GetProtectionAdminOperationAsync(failedLaunch.OperationId)).Value.Operation;
            Check(failedOperation.Status == "RequiresManualIntervention" && failedOperation.RequiresManualIntervention &&
                failedOperation.RetryDisposition == "RequiresManualIntervention" && failedOperation.CompletedAtUtc is null,
                "M4 provider verification failure matches the worker's manual-intervention contract");
            Check(failedOperation.Steps[0].Status == "Completed" &&
                failedOperation.Steps[1] is { Status: "RequiresManualIntervention", AttemptCount: 1, CompletedAtUtc: null } &&
                failedOperation.Steps[1].FailureCode == "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED",
                "M4 discovery failure does not overwrite completed validation or invent a completion timestamp");
            Check(failedOperation.Steps.Skip(2).All(step =>
                step is { Status: "Pending", AttemptCount: 0, StartedAtUtc: null, CompletedAtUtc: null }),
                "M4 connection failure retains later steps as genuinely unrun");
            var failedConnectionReadback = (await failedConnection.Api.GetPurviewTenantConnectionAsync()).Value.Connection;
            Check(failedConnectionReadback is { Status: "VerificationFailed", AuthorityKind: "VerificationFailed",
                ActiveInventoryGenerationId: null, AuthorizedAtUtc: null, LastVerifiedAtUtc: null, ExpiresAtUtc: null },
                "M4 failed connection clears the unusable authority and inventory lifetime");
            var restrictedProtection = Create("m4-ready", "Operator");
            var inventoryDenied = await Throws<GatewayApiException>(() => restrictedProtection.Api.GetPurviewSensitiveInformationTypesAsync());
            Check(inventoryDenied.StatusCode == HttpStatusCode.Forbidden, "M4 operator cannot read administrator inventory");
            Console.WriteLine($"BROWSER_FIXTURE_SELF_TEST passed={checks}; failed=0; realNetworkCalls=0");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"BROWSER_FIXTURE_SELF_TEST failed after {checks} checks: {exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }
}
