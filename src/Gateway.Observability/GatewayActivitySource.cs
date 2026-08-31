using System.Diagnostics;

namespace Gateway.Observability;

public static class GatewayActivitySource
{
    public const string Name = "A365.CustomGateway";

    public static readonly ActivitySource Instance = new(Name);

    public static class Operations
    {
        public const string MirrorSanitizedTelemetry = "MirrorSanitizedTelemetry";
    }
}
