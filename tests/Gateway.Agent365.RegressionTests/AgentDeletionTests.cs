using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

internal static class AgentDeletionTests
{
    public static async Task RunAsync()
    {
        var accessStore = new Store();
        accessStore.Agent.ExternalAgentId = new Gateway.Domain.ValueObjects.ExternalAgentId("access-test");
        var registryId = accessStore.Agent.Agent365InstanceId;
        var revision = accessStore.Agent.ProtectionRevision;
        await new DisableAgentHandler(accessStore, accessStore, accessStore).Handle(new DisableAgentCommand(accessStore.Agent.Id, "admin"), default);
        if (accessStore.Agent.Status != AgentStatus.Disabled || accessStore.Agent.ProtectionRevision == revision || accessStore.Agent.Agent365InstanceId != registryId || accessStore.Agent.IsDeleted)
            throw new Exception("Disable must change gateway admission only and invalidate prior protection receipts.");
        var activity = new Gateway.Application.Activities.Commands.SubmitActivityHandler(accessStore, null!, null!, null!, accessStore, accessStore);
        try
        {
            await activity.Handle(new Gateway.Application.Activities.Commands.SubmitActivityCommand("access-test", "test", null, "Chat", DateTime.UtcNow, null!, null, null, accessStore.Agent.Id, null), default);
            throw new Exception("Disabled agent admitted activity.");
        }
        catch (DomainException ex) when (ex.ErrorCode == Gateway.Contracts.ErrorCodes.AGENT_DISABLED) { }
        await new EnableAgentHandler(accessStore, accessStore, accessStore).Handle(new EnableAgentCommand(accessStore.Agent.Id, "admin"), default);
        if (accessStore.Agent.Status != AgentStatus.Active || accessStore.Agent.Agent365InstanceId != registryId) throw new Exception("Enable changed registration.");
        Console.WriteLine("Gateway disable/enable preserves registration and rejects disabled activity before any export.");
        foreach (var mode in new[] { "success", "failure", "stale", "provisioning" })
        {
            var store = new Store();
            var registry = new Registry(store, mode);
            if (mode == "provisioning") store.Agent.Status = AgentStatus.Provisioning;
            var handler = new DeleteAgentHandler(store, store, store, store, registry);
            try
            {
                await handler.Handle(new DeleteAgentCommand(store.Agent.Id, "admin", mode == "stale" ? "stale" : "AQ=="), CancellationToken.None);
                if (mode != "success") throw new Exception("Unsafe deletion accepted.");
            }
            catch (ConflictException) when (mode == "stale") { }
            catch (InvalidStateTransitionException) when (mode == "provisioning") { }
            catch (DomainException) when (mode == "failure") { }
            if (store.Agent.IsDeleted != (mode == "success")) throw new Exception("Unverified local deletion.");
            if (mode is "stale" or "provisioning" && registry.Calls != 0) throw new Exception("Rejected request reached Microsoft.");
            if (mode == "failure")
            {
                if (store.Agent.Status != AgentStatus.Deleting) throw new Exception("Failed deletion restored runtime access.");
                registry.Fail = false;
                await handler.Handle(new DeleteAgentCommand(store.Agent.Id, "admin", "AQ=="), CancellationToken.None);
                if (!store.Agent.IsDeleted || store.Jobs.Count != 1) throw new Exception("Retry did not reconcile the original operation.");
            }
        }
        Console.WriteLine("Deletion lifecycle: stale/provisioning rejection, runtime denial before Graph, failure retention and retry passed.");
    }
    private sealed class Registry(Store store, string mode) : IAgent365DelegatedRegistryClient
    {
        public int Calls; public bool Fail = mode == "failure";
        public Task DeleteAsync(Guid r, Guid i, Guid b, CancellationToken ct)
        {
            Calls++;
            if (store.Saves == 0 || store.Agent.Status != AgentStatus.Deleting || store.Agent.IsDeleted) throw new Exception("External delete before durable runtime denial.");
            if (Fail) throw new HttpRequestException("simulated outage");
            return Task.CompletedTask;
        }
        public Task<string> CreateAsync(Agent365DelegatedRegistryRequest r, CancellationToken ct) => throw new NotSupportedException();
        public Task VerifyAsync(string id, Agent365DelegatedRegistryRequest r, CancellationToken ct) => throw new NotSupportedException();
    }
    private sealed class Store : IAgentRepository, IProvisioningJobRepository, IAuditEventRepository, IUnitOfWork
    {
        public AgentRegistration Agent = new() { Id=Guid.NewGuid(), Status=AgentStatus.Active, RowVersion=[1],
            Agent365InstanceId=Guid.NewGuid().ToString(), AgentIdentityObjectId=Guid.NewGuid().ToString(), BlueprintId=Guid.NewGuid().ToString() };
        public List<ProvisioningJob> Jobs = []; public int Saves;
        Task<AgentRegistration?> IAgentRepository.GetByIdAsync(Guid id, CancellationToken ct) => Task.FromResult<AgentRegistration?>(Agent);
        public Task<(List<AgentRegistration>, int)> ListAsync(AgentListFilter f, CancellationToken ct) => throw new NotSupportedException();
        public Task AddAsync(AgentRegistration a, CancellationToken ct) => throw new NotSupportedException();
        public Task<bool> ExistsAsync(string id, CancellationToken ct) => Task.FromResult(false);
        Task<ProvisioningJob?> IProvisioningJobRepository.GetByIdAsync(Guid id, CancellationToken ct) => Task.FromResult(Jobs.Find(j=>j.Id==id));
        public Task<List<ProvisioningJob>> GetByAgentIdAsync(Guid id, CancellationToken ct) => Task.FromResult(Jobs);
        public Task AddAsync(ProvisioningJob j, CancellationToken ct) { Jobs.Add(j); return Task.CompletedTask; }
        public Task<bool> ExistsAsync(Guid id, CancellationToken ct) => Task.FromResult(false);
        public Task AddAsync(AuditEvent a, CancellationToken ct) => Task.CompletedTask;
        public Task<(List<AuditEvent>, string?)> GetByAgentIdAsync(Guid id, int limit, string? cursor, CancellationToken ct) => throw new NotSupportedException();
        public Task<int> SaveChangesAsync(CancellationToken ct) { Saves++; return Task.FromResult(1); }
    }
}
