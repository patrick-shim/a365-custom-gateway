namespace Gateway.Domain.Interfaces;

/// <summary>
/// Acquires a Microsoft Graph token on behalf of the currently authenticated
/// Gateway administrator. The clear token is process-local and must not be logged
/// or persisted.
/// </summary>
public interface IAgent365DelegatedTokenProvider
{
    Task<string> GetTokenAsync(CancellationToken cancellationToken);
}
