namespace Gateway.Api.Options;

public sealed class Agent365DelegatedRegistryOptions
{
    public const string SectionName = "Agent365:DelegatedRegistry";
    public const string ScopeKeySection = SectionName + ":Scopes";

    public bool Enabled { get; init; }

    // Development-only deployments may continuously expose this authenticated,
    // administrator-only delegated action. IaC prevents enabling it elsewhere.
    public bool AllowContinuousDevelopmentAccess { get; init; }

    public string[] Scopes { get; init; } =
    [
        "https://graph.microsoft.com/AgentRegistration.ReadWrite.All",
        "https://graph.microsoft.com/AgentRegistration.Read.All"
    ];
}
