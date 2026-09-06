namespace Gateway.Purview;

internal sealed class RemotePurviewSettingsAutomation(IPurviewExecutorClient executor)
    : IPurviewSettingsAutomation
{
    public Task<PurviewProviderReadback<PurviewKnowYourDataReadback>> ReadKnowYourDataAsync(
        PurviewKnowYourDataIntent intent, CancellationToken cancellationToken) =>
        executor.ReadAsync<PurviewKnowYourDataIntent, PurviewProviderReadback<PurviewKnowYourDataReadback>>(
            PurviewExecutorCommand.ReadKnowYourData, intent.OperationId, intent.TenantId,
            intent, cancellationToken);

    public Task CreateKnowYourDataAsync(PurviewKnowYourDataIntent intent, CancellationToken cancellationToken) =>
        executor.MutateAsync(PurviewExecutorCommand.CreateKnowYourData,
            intent.OperationId, intent.TenantId, intent, cancellationToken);

    public Task<PurviewProviderReadback<PurviewDlpProfileReadback>> ReadDlpProfileAsync(
        PurviewDlpProfileIntent intent, CancellationToken cancellationToken) =>
        executor.ReadAsync<PurviewDlpProfileIntent, PurviewProviderReadback<PurviewDlpProfileReadback>>(
            PurviewExecutorCommand.ReadDlpProfile, intent.OperationId, intent.TenantId,
            intent, cancellationToken);

    public Task CreateDlpPolicyAsync(PurviewDlpProfileIntent intent, CancellationToken cancellationToken) =>
        executor.MutateAsync(PurviewExecutorCommand.CreateDlpPolicy,
            intent.OperationId, intent.TenantId, intent, cancellationToken);

    public Task CreateDlpRuleAsync(PurviewDlpProfileIntent intent, CancellationToken cancellationToken) =>
        executor.MutateAsync(PurviewExecutorCommand.CreateDlpRule,
            intent.OperationId, intent.TenantId, intent, cancellationToken);
}
