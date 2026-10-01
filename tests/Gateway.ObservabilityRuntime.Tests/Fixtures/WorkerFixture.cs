using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Provisioning.Worker;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.Fixtures;

// This snapshot boundary models SaveChanges/reopening only. It is not a SQL transaction or replica-lock test.
internal sealed class WorkerStore : IAgentRepository, IProvisioningJobRepository,
    IActivityReceiptRepository, IAiInteractionRepository, IAuditEventRepository,
    IOutboxRepository, IUnitOfWork, IProvisioningExecutionLockProvider
{
    private string? committed;
    public AgentRegistration Agent { get; private set; }
    public AiInteractionRecord Interaction { get; private set; }
    public ActivityReceipt Receipt { get; private set; }
    public ProvisioningJob? Job { get; set; }
    public List<ProvisioningJob> PriorJobs { get; private set; } = [];
    public List<AuditEvent> Audits { get; private set; } = [];
    public List<OutboxMessage> Outbox { get; private set; } = [];
    public List<Checkpoint> Saves { get; } = [];
    public bool LeaseHeld { get; private set; }
    public int LeaseAcquisitions { get; private set; }
    public int LeaseReleases { get; private set; }

    public WorkerStore()
    {
        Agent = new()
        {
            Id = FixtureIds.Agent,
            ExternalAgentId = new("offline-agent"),
            Name = "Offline agent",
            OwnerObjectId = FixtureIds.Actor.ToString("D"),
            Status = AgentStatus.Active,
            Environment = AgentEnvironment.Test,
            Agent365AgentId = FixtureIds.Child.ToString("D"),
            BlueprintId = FixtureIds.Blueprint.ToString("D"),
            FeatureConfiguration = new()
            {
                AgentRegistrationId = FixtureIds.Agent,
                ObservabilityMode = ObservabilityMode.Agent365AzureMonitor
            }
        };
        Interaction = new()
        {
            Id = FixtureIds.Registry,
            AgentRegistrationId = Agent.Id,
            ExternalInteractionId = "offline-interaction",
            CorrelationId = "offline-correlation",
            SessionId = "offline-session",
            TenantUserObjectId = FixtureIds.Actor.ToString("D"),
            ProcessingStatus = ProcessingStatus.Accepted,
            ObservabilityStatus = "Queued",
            OccurredAtUtc = FixtureIds.Timestamp,
            ReceivedAtUtc = FixtureIds.Timestamp.AddSeconds(1)
        };
        Receipt = new()
        {
            Id = FixtureIds.Principal,
            AgentRegistrationId = Agent.Id,
            ExternalActivityId = "offline-activity",
            CorrelationId = "offline-activity-correlation",
            ActivityType = ActivityType.ToolInvocation,
            ProcessingStatus = ProcessingStatus.Accepted,
            OccurredAtUtc = FixtureIds.Timestamp,
            ReceivedAtUtc = FixtureIds.Timestamp.AddSeconds(1)
        };
    }

    public ProvisioningMessageHandler Handler(WorkerProviders providers, bool executionEnabled = true) => new(
        providers, this, this, this, this, providers, this, this, this, this,
        Options.Create(new ProvisioningWorkerOptions { ProvisioningExecutionEnabled = executionEnabled }),
        NullLogger<ProvisioningMessageHandler>.Instance);

    public WorkerStore ReopenCommitted()
    {
        var snapshot = JsonSerializer.Deserialize<Snapshot>(committed
            ?? throw new InvalidOperationException("Reopening requires a saved checkpoint."))!;
        snapshot.Agent.ExternalAgentId = new ExternalAgentId(snapshot.ExternalId);
        return new WorkerStore
        {
            Agent = snapshot.Agent,
            Interaction = snapshot.Interaction,
            Receipt = snapshot.Receipt,
            Job = snapshot.Job,
            PriorJobs = snapshot.PriorJobs,
            Audits = snapshot.Audits,
            Outbox = snapshot.Outbox,
            committed = committed
        };
    }

    public Task<int> SaveChangesAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Saves.Add(new(Interaction.ObservabilityStatus, Interaction.ProcessingStatus,
            Receipt.ProcessingStatus, Job?.Status, Audits.Select(item => item.EventType).ToArray()));
        committed = JsonSerializer.Serialize(new Snapshot(
            Agent.ExternalAgentId.Value, Agent, Interaction, Receipt, Job, PriorJobs, Audits, Outbox));
        return Task.FromResult(1);
    }

    Task<AgentRegistration?> IAgentRepository.GetByIdAsync(Guid id, CancellationToken ct) =>
        Task.FromResult(id == Agent.Id ? Agent : null);
    Task<(List<AgentRegistration>, int)> IAgentRepository.ListAsync(AgentListFilter filter, CancellationToken ct) => throw Unexpected();
    Task IAgentRepository.AddAsync(AgentRegistration agent, CancellationToken ct) => throw Unexpected();
    Task<bool> IAgentRepository.ExistsAsync(string externalAgentId, CancellationToken ct) => throw Unexpected();

    Task<AiInteractionRecord?> IAiInteractionRepository.GetByIdAsync(Guid id, CancellationToken ct) =>
        Task.FromResult(id == Interaction.Id ? Interaction : null);
    Task IAiInteractionRepository.AddAsync(AiInteractionRecord record, CancellationToken ct) => throw Unexpected();
    Task<IReadOnlyDictionary<Guid, DateTime>> IAiInteractionRepository.GetLatestReceivedAtUtcAsync(
        IReadOnlyCollection<Guid> ids, CancellationToken ct) => throw Unexpected();

    Task<ActivityReceipt?> IActivityReceiptRepository.GetByIdAsync(Guid id, CancellationToken ct) =>
        Task.FromResult(id == Receipt.Id ? Receipt : null);
    Task IActivityReceiptRepository.AddAsync(ActivityReceipt receipt, CancellationToken ct) => throw Unexpected();
    Task<bool> IActivityReceiptRepository.ExistsByExternalIdAsync(Guid agentId, string externalId, CancellationToken ct) => throw Unexpected();
    Task<IReadOnlyDictionary<Guid, DateTime>> IActivityReceiptRepository.GetLatestReceivedAtUtcAsync(
        IReadOnlyCollection<Guid> ids, CancellationToken ct) => throw Unexpected();

    Task<ProvisioningJob?> IProvisioningJobRepository.GetByIdAsync(Guid id, CancellationToken ct) =>
        Task.FromResult(Job?.Id == id ? Job : PriorJobs.SingleOrDefault(item => item.Id == id));
    Task<List<ProvisioningJob>> IProvisioningJobRepository.GetByAgentIdAsync(Guid id, CancellationToken ct) =>
        Task.FromResult(PriorJobs.Concat(Job is null ? [] : new[] { Job }).Where(item => item.AgentRegistrationId == id).ToList());
    Task IProvisioningJobRepository.AddAsync(ProvisioningJob job, CancellationToken ct) => throw Unexpected();

    public Task<bool> ExistsAsync(Guid id, CancellationToken ct) =>
        Task.FromResult(Audits.Any(item => item.Id == id));
    public Task AddAsync(AuditEvent auditEvent, CancellationToken ct)
    {
        Assert.DoesNotContain(Audits, item => item.Id == auditEvent.Id);
        Audits.Add(auditEvent);
        return Task.CompletedTask;
    }
    Task<(List<AuditEvent>, string?)> IAuditEventRepository.GetByAgentIdAsync(
        Guid agentId, int limit, string? cursor, CancellationToken ct) => throw Unexpected();

    public Task AddAsync(OutboxMessage message, CancellationToken ct)
    {
        Outbox.Add(message);
        return Task.CompletedTask;
    }
    Task<IReadOnlyList<OutboxMessage>> IOutboxRepository.ClaimPendingAsync(
        int batchSize, DateTime utcNow, DateTime expiresAt, CancellationToken ct) => throw Unexpected();
    Task<bool> IOutboxRepository.MarkPublishedAsync(Guid id, DateTime expiresAt, DateTime publishedAt, CancellationToken ct) => throw Unexpected();
    Task<bool> IOutboxRepository.MarkFailedAsync(Guid id, DateTime expiresAt, DateTime? retryAt, bool terminal, CancellationToken ct) => throw Unexpected();

    public Task<IProvisioningExecutionLease> AcquireAsync(Guid jobId, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Assert.Equal(Job!.Id, jobId);
        Assert.False(LeaseHeld);
        LeaseHeld = true;
        LeaseAcquisitions++;
        return Task.FromResult<IProvisioningExecutionLease>(new Lease(this));
    }

    private sealed class Lease(WorkerStore owner) : IProvisioningExecutionLease
    {
        public ValueTask DisposeAsync()
        {
            Assert.True(owner.LeaseHeld);
            owner.LeaseHeld = false;
            owner.LeaseReleases++;
            return ValueTask.CompletedTask;
        }
    }

    private static UnexpectedFixtureCallException Unexpected() => new("This repository operation was not scripted.");
    internal sealed record Checkpoint(
        string ObservabilityStatus, ProcessingStatus InteractionStatus, ProcessingStatus ActivityStatus,
        JobStatus? JobStatus, IReadOnlyList<string> AuditTypes);
    private sealed record Snapshot(
        string ExternalId, AgentRegistration Agent, AiInteractionRecord Interaction, ActivityReceipt Receipt,
        ProvisioningJob? Job, List<ProvisioningJob> PriorJobs, List<AuditEvent> Audits, List<OutboxMessage> Outbox);
}

internal sealed class WorkerProviders : IAgent365ProvisioningClient, IObservabilityExporter
{
    public FiniteCalls<Agent365ProvisioningStepRequest, Agent365ProvisioningStepResult> Steps { get; } = new();
    public FiniteCalls<ObservabilityExportRequest, bool> Exports { get; } = new();
    public Task<Agent365ProvisioningStepResult> ExecuteStepAsync(Agent365ProvisioningStepRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(Steps.Invoke(request));
    }
    public Task ExportActivityAsync(ObservabilityExportRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Exports.Invoke(request);
        return Task.CompletedTask;
    }
    public void AssertComplete()
    {
        Steps.AssertComplete();
        Exports.AssertComplete();
    }
}
