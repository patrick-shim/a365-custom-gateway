using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Activities.Commands;

public sealed record SubmitActivityCommand(
    string ExternalAgentId,
    string ActivityId,
    string? SessionId,
    string ActivityType,
    DateTime OccurredAtUtc,
    ActorDto Actor,
    ToolDto? Tool,
    Dictionary<string, string>? Attributes,
    Guid CallerAgentRegistrationId,
    string? IdempotencyKey) : IRequest<ActivityReceiptDto>;
