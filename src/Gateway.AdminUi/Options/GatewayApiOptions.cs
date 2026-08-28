namespace Gateway.AdminUi.Options;

public sealed class GatewayApiOptions
{
    public const string SectionName = "GatewayApi";

    public Uri? BaseUrl { get; set; }

    public string[] Scopes { get; set; } = [];

    public int TimeoutSeconds { get; set; } = 30;
}
