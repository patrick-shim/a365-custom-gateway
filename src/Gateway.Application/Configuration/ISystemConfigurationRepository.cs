using Gateway.Domain.Entities;

namespace Gateway.Application.Configuration;

public interface ISystemConfigurationRepository
{
    Task<SystemConfiguration?> GetAsync(CancellationToken ct);
}
