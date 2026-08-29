using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Prompts.Commands;

public sealed record EvaluatePromptCommand(
    string ExternalAgentId,
    string InteractionId,
    DateTime OccurredAtUtc,
    UserContextDto? UserContext,
    ContentDto Prompt,
    Guid CallerAgentRegistrationId,
    string IdempotencyKey) : IRequest<PromptEvaluationResultDto>;
