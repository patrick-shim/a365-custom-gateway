using Gateway.Contracts;
using MediatR;

namespace Gateway.Application.Activities.Commands;

public sealed record SubmitBatchActivityCommand(
    string ExternalAgentId,
    List<BatchActivityItemDto> Activities,
    string CallerClientId) : IRequest<BatchActivityResponse>;
