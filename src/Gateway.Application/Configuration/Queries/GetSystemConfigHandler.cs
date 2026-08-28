using Gateway.Application.Exceptions;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Configuration.Queries;

internal sealed class GetSystemConfigHandler : IRequestHandler<GetSystemConfigQuery, SystemConfigDto>
{
    private readonly ISystemConfigurationRepository _configRepository;

    public GetSystemConfigHandler(ISystemConfigurationRepository configRepository)
    {
        _configRepository = configRepository;
    }

    public async Task<SystemConfigDto> Handle(GetSystemConfigQuery request, CancellationToken cancellationToken)
    {
        var config = await _configRepository.GetAsync(cancellationToken)
            ?? throw new NotFoundException("SystemConfiguration", "singleton");

        return SystemConfigMapper.ToDto(config);
    }
}
