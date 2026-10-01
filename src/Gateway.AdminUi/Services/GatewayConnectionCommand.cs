namespace Gateway.AdminUi.Services;

public static class GatewayConnectionCommand
{
    public static bool IsShareableEndpoint(Uri? endpoint) =>
        endpoint is { IsAbsoluteUri: true } &&
        (endpoint.Scheme == Uri.UriSchemeHttps ||
         endpoint.Scheme == Uri.UriSchemeHttp && endpoint.IsLoopback) &&
        string.IsNullOrEmpty(endpoint.UserInfo) &&
        string.IsNullOrEmpty(endpoint.Query) &&
        string.IsNullOrEmpty(endpoint.Fragment);

    public static bool SupportsSample(Uri? endpoint) =>
        IsShareableEndpoint(endpoint) && endpoint!.Scheme == Uri.UriSchemeHttps;

    public static string CreateSample(Uri endpoint, string externalAgentId)
    {
        if (!SupportsSample(endpoint))
        {
            throw new ArgumentException("The external-agent sample requires a shareable HTTPS Gateway API endpoint.", nameof(endpoint));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(externalAgentId);
        return $"""
            dotnet run --project .\src\ExternalAgent.Sample -- `
              --api-base-url {Quote(endpoint.AbsoluteUri)} `
              --external-agent-id {Quote(externalAgentId)} `
              --tenant-user-object-id '<tenant-user-object-id>' `
              --message 'Hello through the Gateway'
            """;
    }

    private static string Quote(string value) => $"'{value.Replace("'", "''", StringComparison.Ordinal)}'";
}
