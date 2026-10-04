using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;

namespace Gateway.Application.Prompts;

// The verdict and this outbox item commit in the same ingress transaction.
// No prompt, provider response, or credential is placed on the queue.
internal sealed class PromptShieldTelemetry(
    IActivityReceiptRepository activities,
    IOutboxRepository outbox)
{
    public async Task EnqueueBlockedAsync(
        AgentRegistration agent, PromptEvaluationRecord evaluation, CancellationToken ct)
    {
        if (evaluation.PromptShieldDecision != PromptShieldDecisionType.Blocked ||
            !agent.FeatureConfiguration.ObservabilityMode.ToDestinations().Agent365ObservabilityEnabled)
            return;

        await activities.AddAsync(new ActivityReceipt
        {
            Id = evaluation.Id,
            AgentRegistrationId = agent.Id,
            ExternalActivityId = $"gateway-prompt-shield-{evaluation.Id:D}",
            SessionId = evaluation.ExternalInteractionId,
            ActivityType = ActivityType.ToolInvocation,
            ActorType = ActorType.User,
            ProcessingStatus = ProcessingStatus.Accepted,
            CorrelationId = evaluation.CorrelationId,
            OccurredAtUtc = evaluation.CreatedAtUtc,
            ReceivedAtUtc = evaluation.CreatedAtUtc
        }, ct);
        await outbox.AddAsync(new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "ProcessActivity",
            Payload = JsonSerializer.Serialize(new
            {
                AgentId = agent.Id,
                ReceiptId = evaluation.Id,
                evaluation.CorrelationId,
                ActorTenantUserObjectId = evaluation.TenantUserObjectId,
                Agent365ObservabilityEnabled = true,
                AzureMonitorExportEnabled = false,
                PromptEvaluationId = evaluation.Id
            }),
            Status = OutboxMessageStatus.Pending,
            CreatedAtUtc = evaluation.CreatedAtUtc
        }, ct);
    }
}
