using Gateway.Application.Agents.Commands;
using Gateway.Application.Interactions.Commands;
using Gateway.Application.Prompts.Commands;
using Gateway.Application.Protection;
using Gateway.ContentSafety;
using Gateway.Domain.Entities;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.Infrastructure.Security;
using Gateway.Infrastructure.Services;
using Gateway.TestSupport;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.IntegrationTests.Fixtures;

internal sealed class GatewaySqlHarness
{
    public GatewaySqlHarness(GatewayDbContext context, OfflinePromptShield? shield = null,
        OfflineContentStore? content = null, TimeProvider? clock = null)
    {
        Context = context;
        Shield = shield ?? new();
        Content = content ?? new();
        Clock = clock ?? TimeProvider.System;
        Credentials = new(context, Options.Create(new AgentIngressCredentialOptions()));
        var options = new PromptShieldOptions { Enabled = true, Endpoint = TestData.ShieldEndpoint };
        var binding = new BootstrapPromptShieldRuntimeBinding(
            new ConfigurationBuilder().AddInMemoryCollection(TestData.ShieldConfiguration()).Build(), () => options);
        Protection = new(new ProtectionCapabilityRepository(context), new PurviewDlpProfileRepository(context), Clock, binding);
    }

    public GatewayDbContext Context { get; }
    public TimeProvider Clock { get; }
    public OfflineBlueprintCatalog Catalog { get; } = new();
    public OfflinePromptShield Shield { get; }
    public OfflinePurview Purview { get; } = new();
    public OfflineContentStore Content { get; }
    public AgentIngressCredentialService Credentials { get; }
    public ProtectionEffectiveFeatureEvaluator Protection { get; }
    public PromptEvaluationRepository PromptRepository => new(Context, Clock);

    public RegisterAgentHandler Register() => new(
        new AgentRegistrationRepository(Context), new ProvisioningJobRepository(Context),
        new OutboxRepository(Context), new AuditEventRepository(Context),
        new SystemConfigurationRepository(Context), Catalog, Credentials, Purview, Shield,
        new UnitOfWork(Context), Protection);

    public IssueAgentIngressCredentialHandler Issue() => new(
        new AgentRegistrationRepository(Context), Credentials, new AuditEventRepository(Context), new UnitOfWork(Context));

    public RevokeAgentIngressCredentialHandler Revoke() => new(
        new AgentRegistrationRepository(Context), Credentials, new AuditEventRepository(Context), new UnitOfWork(Context));

    public EvaluatePromptHandler Evaluate() => new(
        new AgentRegistrationRepository(Context), PromptRepository, Shield, Purview,
        new IdempotencyService(Context), new AuditEventRepository(Context), new UnitOfWork(Context),
        Clock, NullLogger<EvaluatePromptHandler>.Instance, Protection);

    public SubmitInteractionHandler Submit() => new(
        new AgentRegistrationRepository(Context), new AiInteractionRepository(Context), Content, Purview,
        new IdempotencyService(Context), new OutboxRepository(Context), new AuditEventRepository(Context),
        PromptRepository, new UnitOfWork(Context), NullLogger<SubmitInteractionHandler>.Instance, Protection);

    public static EvaluatePromptCommand Evaluation(AgentRegistration agent, string key = "evaluate-1") => new(
        agent.ExternalAgentId.Value, "interaction-1", TestData.Now, new(TestData.TenantUser),
        new("text/plain", "Synthetic local prompt"), agent.Id, key);

    public static SubmitInteractionCommand Interaction(AgentRegistration agent, Guid? receiptId, string? key = "submit-1") => new(
        agent.ExternalAgentId.Value, "interaction-1", "session-1", TestData.Now, new(TestData.TenantUser),
        new("text/plain", "Synthetic local prompt"), new("text/plain", "Synthetic local response"),
        null, null, agent.Id, key, receiptId);

    public static OfflinePromptShield AllowingShield() => new()
    {
        IsEnabled = true,
        Evaluate = (_, _, _) => Task.FromResult(new Gateway.Domain.Models.PromptShieldEvaluationResult(false))
    };
}
