using System.Diagnostics;

namespace Gateway.Observability;

public static class GatewayActivitySource
{
    public const string Name = "Gateway.Api";

    public static readonly ActivitySource Instance = new(Name);

    public static class Operations
    {
        public const string RegisterAgent = "RegisterAgent";
        public const string UpdateAgent = "UpdateAgent";
        public const string DeleteAgent = "DeleteAgent";
        public const string SubmitActivity = "SubmitActivity";
        public const string SubmitAiInteraction = "SubmitAiInteraction";
        public const string ProvisionAgent = "ProvisionAgent";
        public const string ReconcileAgent = "ReconcileAgent";
        public const string EvaluatePurview = "EvaluatePurview";
        public const string ExportObservability = "ExportObservability";
        public const string ProcessOutbox = "ProcessOutbox";
        public const string PublishToServiceBus = "PublishToServiceBus";
    }
}
