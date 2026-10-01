using System.Reflection;
using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class M4ProtectionReadbackTests
{
    private static readonly Guid Tenant = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static DateTime Now => TestData.Now;

    [Theory]
    [InlineData(20, 60, 120, 20)]
    [InlineData(120, 20, 60, 20)]
    [InlineData(120, 60, 20, 20)]
    [InlineData(-1, 60, 120, 60)]
    public async Task Agent_and_profile_views_share_the_earliest_known_expiry(
        int connectionMinutes, int runtimeMinutes, int inventoryMinutes, int expectedMinutes)
    {
        foreach (var profileView in new[] { false, true })
        {
            var state = new ProjectionState(connectionMinutes, runtimeMinutes, inventoryMinutes);
            var evaluator = state.Evaluator(profileView);
            var readiness = profileView
                ? (await evaluator.ToProfileDtoAsync(state.Profile, default)).Readiness
                : (await evaluator.ToDtoAsync(state.Agent, default)).PurviewReadiness!;
            Assert.Equal(Now.AddMinutes(expectedMinutes), readiness.ValidUntilUtc);
            Assert.True(readiness.IsReady);
            state.AssertComplete();
        }
    }

    [Fact]
    public async Task Expired_connection_at_equality_does_not_publish_current_readiness()
    {
        var state = new ProjectionState(0, 60, 120);
        var features = await state.Evaluator().ToDtoAsync(state.Agent, default);
        Assert.False(features.PurviewEffectivelyEnabled);
        Assert.Null(features.PurviewReadiness!.ValidUntilUtc);
        Assert.Contains("PURVIEW_INVENTORY_STALE", features.PurviewReadiness.Blockers);
        Assert.Equal("Ready", features.PurviewProfileStatus);
        state.AssertComplete();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Accepted_connection_readback_exposes_launch_only_to_its_actor(bool originalActor)
    {
        var operation = ConnectionOperation();
        var (operations, script) = M4ReadProtocol<IProtectionAdminOperationRepository>.Create();
        script.Return(nameof(IProtectionAdminOperationRepository.GetByIdAsync), operation);
        var reads = Reader(operations);
        var actor = new ProtectionActor(Tenant, originalActor ? TestData.Caller : TestData.Owner);
        var response = await reads.Handle(new GetProtectionAdminOperationQuery(actor, operation.Id), default);
        Assert.Equal(operation.Id, response.Operation.Id);
        Assert.Equal(originalActor, response.CompanionLaunch is not null);
        if (response.CompanionLaunch is { } launch)
        {
            Assert.Equal(operation.Id, launch.OperationId);
            Assert.Equal(Now.AddMinutes(10), launch.ExpiresAtUtc.UtcDateTime);
        }
        script.AssertComplete();
    }

    [Fact]
    public async Task Operation_readback_preserves_the_tenant_boundary()
    {
        var operation = ConnectionOperation();
        var (operations, script) = M4ReadProtocol<IProtectionAdminOperationRepository>.Create();
        script.Return(nameof(IProtectionAdminOperationRepository.GetByIdAsync), operation);
        await Assert.ThrowsAsync<NotFoundException>(() => Reader(operations).Handle(
            new GetProtectionAdminOperationQuery(new ProtectionActor(Guid.NewGuid(), TestData.Caller), operation.Id), default));
        script.AssertComplete();
    }

    [Fact]
    public void Readback_never_refreshes_an_expired_launch_or_creates_an_operation()
    {
        var operation = ConnectionOperation();
        var result = JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(operation.ResultJson!)!;
        var expired = PurviewCompanionLaunchContract.Create(operation.Id, Tenant, Guid.Parse(TestData.Caller),
            result.CompanionLaunch!.InventoryGenerationId, new DateTimeOffset(Now.AddMinutes(-1)));
        operation.ResultJson = JsonSerializer.Serialize(result with { CompanionLaunch = expired });
        var readback = PurviewCompanionLaunchContract.Read(operation);
        Assert.Equal(Now.AddMinutes(-1), readback.ExpiresAtUtc.UtcDateTime);
        Assert.Equal(operation.Id, readback.OperationId);
    }

    [Theory]
    [InlineData("tenant")]
    [InlineData("actor")]
    [InlineData("script")]
    [InlineData("arguments")]
    public void Altered_launch_bindings_are_rejected_instead_of_becoming_a_command(string changed)
    {
        var operation = ConnectionOperation();
        var result = JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(operation.ResultJson!)!;
        var launch = result.CompanionLaunch!;
        launch = changed switch
        {
            "tenant" => PurviewCompanionLaunchContract.Create(operation.Id, Guid.NewGuid(), Guid.Parse(TestData.Caller),
                launch.InventoryGenerationId, launch.ExpiresAtUtc),
            "actor" => PurviewCompanionLaunchContract.Create(operation.Id, Tenant, Guid.Parse(TestData.Owner),
                launch.InventoryGenerationId, launch.ExpiresAtUtc),
            "script" => launch with { ScriptRelativePath = "unreviewed.ps1" },
            _ => launch with { Arguments = launch.Arguments.Concat(["-Command", "unreviewed"]).ToArray() }
        };
        operation.ResultJson = JsonSerializer.Serialize(result with { CompanionLaunch = launch });
        Assert.Throws<DomainException>(() => PurviewCompanionLaunchContract.Read(operation));
    }

    private static ProtectionAdminOperation ConnectionOperation()
    {
        var operation = new ProtectionAdminOperation
        {
            Id = Guid.NewGuid(), TenantId = new(Tenant), ActorObjectId = TestData.Caller,
            Type = ProtectionAdminOperationType.ConnectPurviewTenant,
            Status = ProtectionAdminOperationStatus.AwaitingAdministrator,
            TargetType = ProtectionAdminTargetType.PurviewTenantConnection,
            TargetIdentifier = Guid.NewGuid().ToString("D"), CreatedAtUtc = Now, UpdatedAtUtc = Now,
            ReviewedPayloadHash = "sha256:" + new string('a', 64), CorrelationId = Guid.NewGuid()
        };
        var launch = PurviewCompanionLaunchContract.Create(operation.Id, Tenant, Guid.Parse(TestData.Caller),
            Guid.NewGuid(), new DateTimeOffset(Now.AddMinutes(10)));
        operation.ResultJson = JsonSerializer.Serialize(
            new ProtectionOperationAcceptedResponse(operation.Id, "AwaitingAdministrator", operation.CorrelationId, launch));
        return operation;
    }

    private static ProtectionReadQueriesHandler Reader(IProtectionAdminOperationRepository operations)
    {
        var (capabilities, _) = M4ReadProtocol<IProtectionCapabilityRepository>.Create();
        var (connections, _) = M4ReadProtocol<IPurviewTenantConnectionRepository>.Create();
        var (inventory, _) = M4ReadProtocol<IPurviewSensitiveInformationTypeSnapshotRepository>.Create();
        var (collection, _) = M4ReadProtocol<IPurviewKnowYourDataConfigurationRepository>.Create();
        var (profiles, _) = M4ReadProtocol<IPurviewDlpProfileRepository>.Create();
        var clock = new FixedTimeProvider(Now);
        return new(capabilities, connections, inventory, collection, profiles, operations, clock,
            new ProtectionEffectiveFeatureEvaluator(capabilities, profiles, clock));
    }

    private sealed class ProjectionState
    {
        public AgentRegistration Agent { get; } = TestData.Agent(purview: true);
        public PurviewDlpProfile Profile { get; } = TestData.ReadyProfile();
        private readonly PurviewTenantConnection connection;
        private readonly PurviewSensitiveInformationTypeSnapshotGeneration inventory;
        private readonly List<Action> checks = [];

        public ProjectionState(int connectionMinutes, int runtimeMinutes, int inventoryMinutes)
        {
            Profile.RuntimeBehaviorVerifiedUntilUtc = Now.AddMinutes(runtimeMinutes);
            Profile.SensitiveInformationTypeSnapshotExpiresAtUtc = Now.AddMinutes(inventoryMinutes);
            Profile.SensitiveInformationTypes.Add(new(Profile.SensitiveInformationTypeId.Value, Profile.SensitiveInformationTypeName, 1, -1, 75, 100));
            Agent.BlueprintId = Profile.BlueprintApplicationId.Value.ToString("D");
            connection = new()
            {
                Id = Guid.NewGuid(), TenantId = new(Tenant), Status = PurviewTenantConnectionStatus.Connected,
                LastVerifiedAtUtc = Now, ExpiresAtUtc = connectionMinutes < 0 ? null : Now.AddMinutes(connectionMinutes),
                ActiveInventoryGenerationId = Profile.InventoryGenerationId
            };
            Profile.PurviewTenantConnectionId = connection.Id;
            inventory = new()
            {
                Id = Profile.InventoryGenerationId, TenantId = connection.TenantId, PurviewTenantConnectionId = connection.Id,
                ExpiresAtUtc = Profile.SensitiveInformationTypeSnapshotExpiresAtUtc,
                Items = [new() { Id = Guid.NewGuid(), GenerationId = Profile.InventoryGenerationId,
                    SensitiveInformationTypeId = Profile.SensitiveInformationTypeId, ExactName = Profile.SensitiveInformationTypeName }]
            };
        }

        public ProtectionEffectiveFeatureEvaluator Evaluator(bool profileView = false)
        {
            var (capabilities, capabilityScript) = M4ReadProtocol<IProtectionCapabilityRepository>.Create();
            var (profiles, profileScript) = M4ReadProtocol<IPurviewDlpProfileRepository>.Create();
            var (connections, connectionScript) = M4ReadProtocol<IPurviewTenantConnectionRepository>.Create();
            var (inventories, inventoryScript) = M4ReadProtocol<IPurviewSensitiveInformationTypeSnapshotRepository>.Create();
            var (certification, certificationScript) = M4ReadProtocol<IPurviewRuntimeCertificationVerifier>.Create();
            capabilityScript.Return<ProtectionCapability?>(nameof(IProtectionCapabilityRepository.GetByKindAsync),
                new() { Kind = ProtectionCapabilityKind.Purview, Status = ProtectionCapabilityStatus.Installed, LastReadbackAtUtc = Now });
            if (!profileView)
            {
                capabilityScript.Return<ProtectionCapability?>(nameof(IProtectionCapabilityRepository.GetByKindAsync), null);
                profileScript.Return<PurviewDlpProfile?>(nameof(IPurviewDlpProfileRepository.GetByBlueprintApplicationIdAsync), Profile);
            }
            connectionScript.Return<PurviewTenantConnection?>(nameof(IPurviewTenantConnectionRepository.GetByIdAsync), connection);
            if (connection.IsUsableAt(Now))
                inventoryScript.Return<PurviewSensitiveInformationTypeSnapshotGeneration?>(
                    nameof(IPurviewSensitiveInformationTypeSnapshotRepository.GetGenerationAsync), inventory);
            if (profileView || connection.IsUsableAt(Now))
                certificationScript.Return(nameof(IPurviewRuntimeCertificationVerifier.IsCurrentAsync), true);
            checks.AddRange([capabilityScript.AssertComplete, profileScript.AssertComplete, connectionScript.AssertComplete,
                inventoryScript.AssertComplete, certificationScript.AssertComplete]);
            return new(capabilities, profiles, new FixedTimeProvider(Now), purviewBinding: new ExactBinding(),
                connections: connections, inventory: inventories, runtimeCertification: certification);
        }

        public void AssertComplete() { foreach (var check in checks) check(); }
    }

    private sealed class ExactBinding : IBootstrapPurviewRuntimeBinding
    {
        public bool IsExact(ProtectionCapability? capability) =>
            capability?.Kind == ProtectionCapabilityKind.Purview && capability.Status == ProtectionCapabilityStatus.Installed;
    }
}

public class M4ReadProtocol<T> : DispatchProxy where T : class
{
    private readonly Queue<(string Method, object Result)> expected = new();
    public static (T Api, M4ReadProtocol<T> Script) Create()
    {
        var api = Create<T, M4ReadProtocol<T>>();
        return api is M4ReadProtocol<T> script ? (api, script) : throw new InvalidOperationException("Unexpected proxy type.");
    }
    public void Return<TResult>(string method, TResult result) => expected.Enqueue((method, Task.FromResult(result)));
    protected override object Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        if (!expected.TryDequeue(out var next) || targetMethod?.Name != next.Method)
            throw new InvalidOperationException("Unexpected M4 repository call; no external fallback exists.");
        return next.Result;
    }
    public void AssertComplete() => Assert.Empty(expected);
}
