using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Activities.Commands;

public sealed record SubmitBatchActivityCommand(
    string ExternalAgentId,
    List<BatchActivityItemDto> Activities,
    Guid CallerAgentRegistrationId,
    string? IdempotencyKey = null) : IRequest<BatchActivityResponse>;
