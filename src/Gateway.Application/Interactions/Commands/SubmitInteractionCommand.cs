using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Interactions.Commands;

public sealed record SubmitInteractionCommand(
    string ExternalAgentId,
    string InteractionId,
    string? SessionId,
    DateTime OccurredAtUtc,
    UserContextDto? UserContext,
    ContentDto Prompt,
    ContentDto Response,
    ModelDto? Model,
    Dictionary<string, string>? Metadata,
    Guid CallerAgentRegistrationId,
    string? IdempotencyKey) : IRequest<InteractionReceiptDto>;
