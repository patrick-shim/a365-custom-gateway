using Gateway.Contracts;
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
    string CallerClientId,
    string? IdempotencyKey) : IRequest<ActivityReceiptDto>;
