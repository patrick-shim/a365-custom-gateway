using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;

namespace Gateway.IntegrationTests.Fixtures;

internal static class TestEntityFactory
{
    public static AgentRegistration CreateAgentRegistration(
        string? externalAgentId = null,
        string? name = null,
        AgentEnvironment environment = AgentEnvironment.Development,
        AgentStatus status = AgentStatus.Draft,
        string? externalClientId = null,
        string? ownerObjectId = null,
        DateTime? createdAtUtc = null,
        bool isDeleted = false)
    {
        var id = Guid.NewGuid();
        var now = createdAtUtc ?? DateTime.UtcNow;

        return new AgentRegistration
        {
            Id = id,
            ExternalAgentId = new ExternalAgentId(externalAgentId ?? $"agent-{Guid.NewGuid():N}"[..20]),
            Name = name ?? $"Test Agent {id:N}"[..20],
            Description = "Test agent for integration tests",
            OwnerObjectId = ownerObjectId ?? Guid.NewGuid().ToString(),
            Environment = environment,
            Status = status,
            ExternalClientId = externalClientId,
            IsDeleted = isDeleted,
            DeletedAtUtc = isDeleted ? now : null,
            CreatedAtUtc = now,
            CreatedByObjectId = Guid.NewGuid().ToString(),
            UpdatedAtUtc = now,
            UpdatedByObjectId = Guid.NewGuid().ToString(),
            RowVersion = new byte[] { 0, 0, 0, 0, 0, 0, 0, 1 },
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = id,
                ObservabilityMode = ObservabilityMode.GatewayOnly,
                PurviewEnabled = false,
                PurviewMode = null,
                UpdatedAtUtc = now,
            },
        };
    }

    public static ProvisioningJob CreateProvisioningJob(
        Guid agentRegistrationId,
        OperationType type = OperationType.ProvisionAgent,
        JobStatus status = JobStatus.Pending,
        int stepCount = 3)
    {
        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentRegistrationId,
            Type = type,
            Status = status,
            PercentComplete = 0,
            StartedAtUtc = DateTime.UtcNow,
            CreatedAtUtc = DateTime.UtcNow,
        };

        for (int i = 0; i < stepCount; i++)
        {
            job.Steps.Add(new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = (ProvisioningStepType)i,
                Status = StepStatus.Pending,
                OrderIndex = i,
            });
        }

        return job;
    }

    public static AuditEvent CreateAuditEvent(
        Guid? agentRegistrationId = null,
        string eventType = "AgentRegistered",
        DateTime? occurredAtUtc = null)
    {
        return new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentRegistrationId,
            EventType = eventType,
            PerformedByObjectId = Guid.NewGuid().ToString(),
            PerformedByRole = "Gateway.Administrator",
            Details = "Test audit event",
            CorrelationId = Guid.NewGuid().ToString(),
            OccurredAtUtc = occurredAtUtc ?? DateTime.UtcNow,
        };
    }

    public static OutboxMessage CreateOutboxMessage(
        OutboxMessageStatus status = OutboxMessageStatus.Pending,
        DateTime? createdAtUtc = null)
    {
        return new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "ProvisioningRequested",
            Payload = """{"agentId":"test-agent-001","operation":"provision"}""",
            Status = status,
            RetryCount = 0,
            CreatedAtUtc = createdAtUtc ?? DateTime.UtcNow,
        };
    }

    public static IdempotencyRecord CreateIdempotencyRecord(
        string? key = null,
        int responseStatusCode = 200,
        DateTime? expiresAtUtc = null)
    {
        return new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            IdempotencyKey = key ?? Guid.NewGuid().ToString(),
            RequestBodyHash = Guid.NewGuid().ToString("N"),
            Endpoint = "/api/v1/agents/test-agent/activities",
            ResponseStatusCode = responseStatusCode,
            ResponseBody = """{"status":"ok"}""",
            CreatedAtUtc = DateTime.UtcNow,
            ExpiresAtUtc = expiresAtUtc ?? DateTime.UtcNow.AddHours(24),
        };
    }
}
