namespace Gateway.AdminUi.Authentication;

public interface IGatewayAccessTokenProvider
{
    Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default);
}
