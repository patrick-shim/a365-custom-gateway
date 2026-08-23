using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public record BatchActivityRequest(
    string ExternalAgentId,
    List<BatchActivityItemDto> Activities);
