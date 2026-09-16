using System.Diagnostics;
using System.Text.Json;
using Gateway.Agent365;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Observability;
using Gateway.ObservabilityRuntime.Tests.Fixtures;

namespace Gateway.ObservabilityRuntime.Tests.Worker;

public sealed class WorkerRecoveryBaselineTests
{
    [Fact]
    public async Task Transient_export_reopens_saved_state_and_does_not_repeat_the_mirror_or_terminal_export()
    {
        var store = new WorkerStore();
        var providers = new WorkerProviders();
        var mirrored = new List<Activity>();
        using var listener = new ActivityListener
        {
            ShouldListenTo = source => source.Name == GatewayActivitySource.Name,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllData,
            ActivityStopped = activity =>
            {
                if (activity.GetTagItem("gateway.event.id") as string == store.Interaction.Id.ToString("D"))
                    mirrored.Add(activity);
            }
        };
        ActivitySource.AddActivityListener(listener);
        providers.Exports.Expect(request =>
        {
            Assert.Equal("Processing", store.Saves[^1].ObservabilityStatus);
            Assert.Contains("AzureMonitorMirrorScheduled", store.Saves[^1].AuditTypes);
            Assert.Equal(store.Agent.Agent365AgentId, request.AgentIdentityClientId);
            throw new Agent365ObservabilityTransientException("NetworkFailure");
        });
        providers.Exports.Expect(_ => true);
        var payload = InteractionMessage(store);

        await Assert.ThrowsAsync<Agent365ObservabilityTransientException>(() =>
            store.Handler(providers).HandleAsync("ExportInteraction", payload, CancellationToken.None));

        Assert.Equal("Queued", store.Saves[^1].ObservabilityStatus);
        Assert.Equal(ProcessingStatus.Accepted, store.Saves[^1].InteractionStatus);
        Assert.Null(store.Interaction.ProcessedAtUtc);
        var reopened = store.ReopenCommitted();
        Assert.NotSame(store.Interaction, reopened.Interaction);
        Assert.False((await reopened.Handler(providers).HandleAsync("ExportInteraction", payload, CancellationToken.None)).ShouldDeadLetter);
        var completed = reopened.ReopenCommitted();
        var timestamp = completed.Interaction.ProcessedAtUtc;
        Assert.False((await completed.Handler(providers).HandleAsync("ExportInteraction", payload, CancellationToken.None)).ShouldDeadLetter);

        Assert.Equal("Completed", completed.Interaction.ObservabilityStatus);
        Assert.Equal(ProcessingStatus.Processed, completed.Interaction.ProcessingStatus);
        Assert.NotNull(timestamp);
        Assert.Equal(timestamp, completed.Interaction.ProcessedAtUtc);
        Assert.Empty(completed.Saves);
        Assert.Single(completed.Audits, item => item.EventType == "AzureMonitorMirrorScheduled");
        Assert.Single(mirrored);
        Assert.Equal(2, providers.Exports.Requests.Count);
        Assert.Equal(providers.Exports.Requests[0], providers.Exports.Requests[1]);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Terminal_export_failure_is_saved_once_and_redelivery_does_not_call_provider()
    {
        var store = new WorkerStore();
        store.Agent.FeatureConfiguration.ObservabilityMode = ObservabilityMode.Agent365;
        var providers = new WorkerProviders();
        providers.Exports.Expect(_ => throw new Agent365ObservabilityConfigurationException("MissingUserContext"));
        var payload = InteractionMessage(store);

        var result = await store.Handler(providers).HandleAsync("ExportInteraction", payload, CancellationToken.None);
        var reopened = store.ReopenCommitted();
        await reopened.Handler(providers).HandleAsync("ExportInteraction", payload, CancellationToken.None);

        Assert.False(result.ShouldDeadLetter);
        Assert.Equal("MissingUserContext", reopened.Interaction.ObservabilityStatus);
        Assert.Equal(ProcessingStatus.Failed, reopened.Interaction.ProcessingStatus);
        Assert.Single(reopened.Audits, item => item.EventType == "ObservabilityExportFailed");
        Assert.Empty(reopened.Saves);
        Assert.Single(providers.Exports.Requests);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Activity_redelivery_preserves_actor_identity_and_retries_only_unfinished_work()
    {
        var store = new WorkerStore();
        store.Agent.FeatureConfiguration.ObservabilityMode = ObservabilityMode.Agent365;
        var providers = new WorkerProviders();
        providers.Exports.Expect(_ => throw new Agent365ObservabilityTransientException("Http503"));
        providers.Exports.Expect(request =>
        {
            Assert.Equal("execute_tool", request.SpanType);
            Assert.Equal(FixtureIds.Actor.ToString("D"), request.TenantUserObjectId);
            Assert.Equal(FixtureIds.Child.ToString("D"), request.AgentIdentityClientId);
            return true;
        });
        var payload = JsonSerializer.Serialize(new
        {
            AgentId = store.Agent.Id,
            ReceiptId = store.Receipt.Id,
            ActorTenantUserObjectId = FixtureIds.Actor.ToString("D")
        });

        await Assert.ThrowsAsync<Agent365ObservabilityTransientException>(() =>
            store.Handler(providers).HandleAsync("ProcessActivity", payload, CancellationToken.None));
        Assert.Equal(ProcessingStatus.Accepted, store.Saves[^1].ActivityStatus);
        var reopened = store.ReopenCommitted();
        await reopened.Handler(providers).HandleAsync("ProcessActivity", payload, CancellationToken.None);
        var completed = reopened.ReopenCommitted();
        await completed.Handler(providers).HandleAsync("ProcessActivity", payload, CancellationToken.None);

        Assert.Equal(ProcessingStatus.Processed, completed.Receipt.ProcessingStatus);
        Assert.Empty(completed.Saves);
        Assert.Equal(2, providers.Exports.Requests.Count);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Exhausted_export_is_durably_terminal_and_does_not_add_duplicate_failure_audits()
    {
        var store = new WorkerStore();
        var providers = new WorkerProviders();
        var payload = InteractionMessage(store);

        var result = await store.Handler(providers).HandleRetryExhaustedAsync(
            "ExportInteraction", payload, "Http503", CancellationToken.None);
        var reopened = store.ReopenCommitted();
        await reopened.Handler(providers).HandleRetryExhaustedAsync(
            "ExportInteraction", payload, "Http503", CancellationToken.None);
        await reopened.Handler(providers).HandleAsync("ExportInteraction", payload, CancellationToken.None);

        Assert.True(result!.ShouldDeadLetter);
        Assert.Equal("ObservabilityRetriesExhausted", result.DeadLetterReason);
        Assert.Equal("Failed", reopened.Interaction.ObservabilityStatus);
        Assert.Equal(ProcessingStatus.Failed, reopened.Interaction.ProcessingStatus);
        Assert.Single(reopened.Audits);
        Assert.Contains("RetriesExhausted", reopened.Audits[0].Details);
        Assert.Empty(reopened.Saves);
        Assert.Empty(providers.Exports.Requests);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Successful_provisioning_step_survives_redelivery_without_reexecution_or_duplicate_outbox()
    {
        var store = new WorkerStore { Job = Job() };
        var providers = new WorkerProviders();
        providers.Steps.Expect(request =>
        {
            Assert.True(store.LeaseHeld);
            Assert.Equal(JobStatus.Running, store.Saves[^1].JobStatus);
            Assert.Equal(ProvisioningStepType.ResolveBlueprint, request.StepType);
            return new(request.StepType, new()
            {
                BlueprintObjectId = FixtureIds.Principal.ToString("D"),
                BlueprintClientId = FixtureIds.Blueprint.ToString("D")
            }, "ExistingBlueprintVerified");
        });
        var payload = ProvisionMessage(store, 0);

        Assert.False((await store.Handler(providers).HandleAsync("ProvisionAgent", payload, CancellationToken.None)).ShouldDeadLetter);
        var reopened = store.ReopenCommitted();
        Assert.False((await reopened.Handler(providers).HandleAsync("ProvisionAgent", payload, CancellationToken.None)).ShouldDeadLetter);

        Assert.Single(providers.Steps.Requests);
        Assert.Equal(StepStatus.Completed, reopened.Job!.Steps.Single(item => item.OrderIndex == 0).Status);
        var next = JsonSerializer.Deserialize<ProvisionAgentMessage>(Assert.Single(reopened.Outbox).Payload)!;
        Assert.Equal(1, next.ExpectedStepIndex);
        Assert.Equal(store.Job.Id, next.JobId);
        Assert.Single(reopened.Audits);
        Assert.Empty(reopened.Saves);
        Assert.Equal(reopened.LeaseAcquisitions, reopened.LeaseReleases);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Access_assignment_stops_at_delegated_registry_boundary_even_after_reopening()
    {
        var store = new WorkerStore { Job = Job(completedPrefix: 4) };
        var providers = new WorkerProviders();
        providers.Steps.Expect(request => new(request.StepType,
            request.State with { ObservabilityAppRoleAssignmentId = FixtureIds.Registry.ToString("D") },
            "Agent365AccessVerified"));

        await store.Handler(providers).HandleAsync("ProvisionAgent", ProvisionMessage(store, 4), CancellationToken.None);
        var reopened = store.ReopenCommitted();
        await reopened.Handler(providers).HandleAsync("ProvisionAgent", ProvisionMessage(reopened, 5), CancellationToken.None);

        Assert.Equal(JobStatus.AwaitingAdministratorAction, reopened.Job!.Status);
        Assert.Equal(AgentStatus.AwaitingAdminApproval, reopened.Agent.Status);
        Assert.Equal(ErrorCodes.AGENT365_REGISTRY_ACTION_REQUIRED, reopened.Job.ErrorCode);
        Assert.Equal(StepStatus.Pending, reopened.Job.Steps.Single(item => item.StepType == ProvisioningStepType.RegisterAgent).Status);
        Assert.Empty(reopened.Outbox);
        Assert.Single(providers.Steps.Requests);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Stale_queued_registry_step_cannot_use_the_worker_application_identity()
    {
        var store = new WorkerStore { Job = Job(completedPrefix: 5) };
        var providers = new WorkerProviders();

        var result = await store.Handler(providers).HandleAsync(
            "ProvisionAgent", ProvisionMessage(store, 5), CancellationToken.None);

        Assert.False(result.ShouldDeadLetter);
        Assert.Empty(providers.Steps.Requests);
        Assert.Empty(store.Saves);
        Assert.Empty(store.Outbox);
        Assert.Equal(store.LeaseAcquisitions, store.LeaseReleases);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Retry_without_verified_prefix_cannot_repeat_an_ambiguous_registry_create()
    {
        var store = new WorkerStore { Job = Job() };
        store.Job.Type = OperationType.RetryProvisioning;
        var prior = Job(completedPrefix: 5);
        prior.Id = FixtureIds.Actor;
        foreach (var step in prior.Steps)
            step.ProvisioningJobId = prior.Id;
        prior.Status = JobStatus.RequiresManualIntervention;
        prior.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        prior.Steps.Single(item => item.StepType == ProvisioningStepType.RegisterAgent).Status = StepStatus.Failed;
        store.PriorJobs.Add(prior);
        var providers = new WorkerProviders();

        var result = await store.Handler(providers).HandleAsync(
            "RetryProvisioning", ProvisionMessage(store, 0), CancellationToken.None);

        Assert.True(result.ShouldDeadLetter);
        Assert.Equal(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT, result.DeadLetterReason);
        Assert.Equal(JobStatus.RequiresManualIntervention, store.ReopenCommitted().Job!.Status);
        Assert.Empty(providers.Steps.Requests);
        Assert.Empty(store.Outbox);
        providers.AssertComplete();
    }

    [Fact]
    public async Task Invalid_persisted_prefix_is_not_treated_as_verified_completion()
    {
        var store = new WorkerStore { Job = Job(completedPrefix: 1) };
        store.Job.Steps.First().ResultData = "{}";
        var providers = new WorkerProviders();

        var result = await store.Handler(providers).HandleAsync(
            "ProvisionAgent", ProvisionMessage(store, 1), CancellationToken.None);

        Assert.True(result.ShouldDeadLetter);
        Assert.Equal(ErrorCodes.PROVISIONING_STATE_INVALID, result.DeadLetterReason);
        Assert.Equal(AgentStatus.RequiresManualIntervention, store.ReopenCommitted().Agent.Status);
        Assert.Empty(providers.Steps.Requests);
        providers.AssertComplete();
    }

    private static string InteractionMessage(WorkerStore store) => JsonSerializer.Serialize(new
    {
        AgentId = store.Agent.Id,
        RecordId = store.Interaction.Id,
        Agent365ObservabilityEnabled = true,
        AzureMonitorExportEnabled = store.Agent.FeatureConfiguration.ObservabilityMode == ObservabilityMode.Agent365AzureMonitor
    });

    private static string ProvisionMessage(WorkerStore store, int index) => JsonSerializer.Serialize(
        new ProvisionAgentMessage(store.Agent.Id, store.Job!.Id, index, "offline-provisioning"));

    private static ProvisioningJob Job(int completedPrefix = 0)
    {
        var job = new ProvisioningJob
        {
            Id = FixtureIds.Registry,
            AgentRegistrationId = FixtureIds.Agent,
            Type = OperationType.ProvisionAgent,
            Status = JobStatus.Running,
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            CreatedAtUtc = FixtureIds.Timestamp
        };
        var state = new Agent365ProvisioningState();
        foreach (var (step, index) in ProvisioningWorkflow.CurrentSteps.Select((step, index) => (step, index)))
        {
            state = step switch
            {
                ProvisioningStepType.ResolveBlueprint => state with
                {
                    BlueprintObjectId = FixtureIds.Principal.ToString("D"),
                    BlueprintClientId = FixtureIds.Blueprint.ToString("D")
                },
                ProvisioningStepType.EnsureBlueprintPrincipal => state with { BlueprintPrincipalObjectId = FixtureIds.Principal.ToString("D") },
                ProvisioningStepType.ConfigureGatewayFederation => state with
                {
                    GatewayManagedIdentityPrincipalId = FixtureIds.Principal.ToString("D"),
                    GatewayFederatedCredentialId = FixtureIds.Actor.ToString("D")
                },
                ProvisioningStepType.CreateAgentIdentity => state with
                {
                    AgentIdentityClientId = FixtureIds.Child.ToString("D"),
                    AgentIdentityObjectId = FixtureIds.Principal.ToString("D")
                },
                ProvisioningStepType.AssignAgent365Access => state with { ObservabilityAppRoleAssignmentId = FixtureIds.Registry.ToString("D") },
                _ => state
            };
            job.Steps.Add(new()
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                OrderIndex = index,
                StepType = step,
                Status = index < completedPrefix ? StepStatus.Completed : StepStatus.Pending,
                ResultData = index < completedPrefix
                    ? JsonSerializer.Serialize(new Agent365ProvisioningStepResult(step, state, "FixtureReadbackVerified"))
                    : null
            });
        }
        return job;
    }
}
