using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Repositories;

public sealed class ProtectionRepositoriesTests
{
    [Fact]
    public async Task CapabilityRepository_ReturnsIndependentCapabilityKinds()
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new ProtectionCapabilityRepository(context);
        var capability = new ProtectionCapability
        {
            Id = Guid.NewGuid(),
            Kind = ProtectionCapabilityKind.Purview,
            Status = ProtectionCapabilityStatus.PendingPropagation,
            ResourceIdentifiers = new ProtectionCapabilityResourceIdentifiers(
                PurviewAutomationApplicationId: new ApplicationClientId(Guid.NewGuid())),
            CreatedAtUtc = UtcNow,
            UpdatedAtUtc = UtcNow,
        };

        await repository.AddAsync(capability, CancellationToken.None);
        await new UnitOfWork(context).SaveChangesAsync(CancellationToken.None);
        context.ChangeTracker.Clear();

        (await repository.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            CancellationToken.None))!
            .Id.Should().Be(capability.Id);
        (await repository.ListAsync(CancellationToken.None))
            .Should().ContainSingle(item => item.Kind == ProtectionCapabilityKind.Purview);
    }

    [Fact]
    public async Task Repositories_RoundTripProtectionGovernanceAndOrderedOperationSteps()
    {
        await using var context = TestDbContextFactory.Create();
        var tenantId = new EntraTenantId(Guid.NewGuid());
        var connection = CreateConnection(tenantId);
        var generation = CreateGeneration(connection.Id, tenantId);
        var kyd = CreateKyd(connection.Id, generation.Id);
        var profile = CreateDlpProfile(connection.Id, generation.Id);
        var operation = CreateOperation(tenantId);
        operation.AddStep(CreateStep(operation.Id, orderIndex: 1));
        operation.AddStep(CreateStep(operation.Id, orderIndex: 0));

        await new PurviewTenantConnectionRepository(context)
            .AddAsync(connection, CancellationToken.None);
        var unitOfWork = new UnitOfWork(context);
        await unitOfWork.SaveChangesAsync(CancellationToken.None);
        await new PurviewSensitiveInformationTypeSnapshotRepository(context)
            .AddGenerationAsync(generation, CancellationToken.None);
        await unitOfWork.SaveChangesAsync(CancellationToken.None);
        connection.ActiveInventoryGenerationId = generation.Id;
        await new PurviewKnowYourDataConfigurationRepository(context)
            .AddAsync(kyd, CancellationToken.None);
        await new PurviewDlpProfileRepository(context)
            .AddAsync(profile, CancellationToken.None);
        await new ProtectionAdminOperationRepository(context)
            .AddAsync(operation, CancellationToken.None);
        await unitOfWork.SaveChangesAsync(CancellationToken.None);
        context.ChangeTracker.Clear();

        (await new PurviewTenantConnectionRepository(context)
            .GetByTenantIdAsync(tenantId, CancellationToken.None))!
            .Id.Should().Be(connection.Id);
        (await new PurviewSensitiveInformationTypeSnapshotRepository(context)
            .GetCurrentGenerationAsync(tenantId, generation.RetrievedAtUtc, CancellationToken.None))!
            .Items.Should().ContainSingle();
        (await new PurviewKnowYourDataConfigurationRepository(context)
            .GetByTenantIdAsync(tenantId, CancellationToken.None))!
            .Id.Should().Be(kyd.Id);
        (await new PurviewDlpProfileRepository(context)
            .GetByBlueprintApplicationIdAsync(profile.BlueprintApplicationId, CancellationToken.None))!
            .Id.Should().Be(profile.Id);

        var loadedOperation = await new ProtectionAdminOperationRepository(context)
            .GetByIdempotencyKeyAsync(
                tenantId,
                operation.IdempotencyKey,
                CancellationToken.None);
        loadedOperation.Should().NotBeNull();
        loadedOperation!.OrderedSteps.Select(step => step.OrderIndex).Should().Equal(0, 1);
        loadedOperation.ConfirmationVerifier.Should().NotBeNull();
        loadedOperation.ConfirmationVerifier!.VerifierSalt.ToArray().Should().Equal(1, 2, 3);
        loadedOperation.ConfirmationVerifier.VerifierHash.ToArray().Should().Equal(4, 5, 6);
    }

    [Fact]
    public async Task SnapshotRepository_RejectsExpiredGenerationAsCurrent()
    {
        await using var context = TestDbContextFactory.Create();
        var tenantId = new EntraTenantId(Guid.NewGuid());
        var connection = CreateConnection(tenantId);
        var generation = CreateGeneration(connection.Id, tenantId);
        await new PurviewTenantConnectionRepository(context)
            .AddAsync(connection, CancellationToken.None);
        var unitOfWork = new UnitOfWork(context);
        await unitOfWork.SaveChangesAsync(CancellationToken.None);
        await new PurviewSensitiveInformationTypeSnapshotRepository(context)
            .AddGenerationAsync(generation, CancellationToken.None);
        await unitOfWork.SaveChangesAsync(CancellationToken.None);
        connection.ActiveInventoryGenerationId = generation.Id;
        await unitOfWork.SaveChangesAsync(CancellationToken.None);

        var current = await new PurviewSensitiveInformationTypeSnapshotRepository(context)
            .GetCurrentGenerationAsync(
                tenantId,
                generation.ExpiresAtUtc,
                CancellationToken.None);

        current.Should().BeNull();
    }

    private static PurviewTenantConnection CreateConnection(EntraTenantId tenantId) => new()
    {
        Id = Guid.NewGuid(),
        TenantId = tenantId,
        Status = PurviewTenantConnectionStatus.Connected,
        CreatedByObjectId = "00000000-0000-4000-8000-000000000001",
        CreatedAtUtc = UtcNow,
        UpdatedAtUtc = UtcNow,
    };

    private static PurviewSensitiveInformationTypeSnapshotGeneration CreateGeneration(
        Guid connectionId,
        EntraTenantId tenantId)
    {
        var generation = new PurviewSensitiveInformationTypeSnapshotGeneration
        {
            Id = new SensitiveInformationTypeSnapshotGenerationId(Guid.NewGuid()),
            PurviewTenantConnectionId = connectionId,
            TenantId = tenantId,
            RetrievedAtUtc = UtcNow,
            ExpiresAtUtc = UtcNow.AddHours(1),
            ItemCount = 1,
            CreatedAtUtc = UtcNow,
        };
        generation.Items.Add(new PurviewSensitiveInformationTypeSnapshot
        {
            Id = Guid.NewGuid(),
            GenerationId = generation.Id,
            SensitiveInformationTypeId = new SensitiveInformationTypeId(Guid.NewGuid()),
            ExactName = "Synthetic financial identifier",
            Publisher = "Contoso",
            SortOrder = 0,
        });
        return generation;
    }

    private static PurviewKnowYourDataConfiguration CreateKyd(
        Guid connectionId,
        SensitiveInformationTypeSnapshotGenerationId generationId) => new()
        {
            Id = Guid.NewGuid(),
            PurviewTenantConnectionId = connectionId,
            InventoryGenerationId = generationId,
            SensitiveInformationTypeId = new SensitiveInformationTypeId(Guid.NewGuid()),
            SensitiveInformationTypeName = "Synthetic financial identifier",
            Mode = PurviewMode.AuditOnly,
            Activities = [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText],
            Status = PurviewKnowYourDataStatus.ReviewRequired,
            ReadbackStatus = ProtectionReadbackStatus.NotChecked,
            CreatedAtUtc = UtcNow,
            UpdatedAtUtc = UtcNow,
        };

    private static PurviewDlpProfile CreateDlpProfile(
        Guid connectionId,
        SensitiveInformationTypeSnapshotGenerationId generationId) => new()
        {
            Id = new PurviewDlpProfileId(Guid.NewGuid()),
            PurviewTenantConnectionId = connectionId,
            BlueprintApplicationId = new BlueprintApplicationId(Guid.NewGuid()),
            DisplayName = "Synthetic profile",
            InventoryGenerationId = generationId,
            SensitiveInformationTypeSnapshotExpiresAtUtc = UtcNow.AddHours(1),
            SensitiveInformationTypeId = new SensitiveInformationTypeId(Guid.NewGuid()),
            SensitiveInformationTypeName = "Synthetic financial identifier",
            Mode = PurviewMode.Enforce,
            Activities = [PurviewPolicyActivity.UploadText],
            Actions = [new PurviewDlpRuleAction(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)],
            Status = PurviewDlpProfileStatus.ReviewRequired,
            CreatedAtUtc = UtcNow,
            UpdatedAtUtc = UtcNow,
        };

    private static ProtectionAdminOperation CreateOperation(EntraTenantId tenantId) => new()
    {
        Id = Guid.NewGuid(),
        Type = ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
        Status = ProtectionAdminOperationStatus.AwaitingConfirmation,
        TenantId = tenantId,
        ActorObjectId = "00000000-0000-4000-8000-000000000001",
        TargetType = ProtectionAdminTargetType.DlpProfile,
        TargetIdentifier = Guid.NewGuid().ToString("D"),
        ReviewedPayloadHash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        IdempotencyKey = new ProtectionIdempotencyKey(Guid.NewGuid()),
        ConfirmationVerifier = new ProtectionConfirmationVerifier(
            Guid.NewGuid(),
            Guid.NewGuid(),
            1,
            "SHA-256",
            [1, 2, 3],
            [4, 5, 6],
            UtcNow.AddMinutes(5)),
        MaximumAttempts = 3,
        CorrelationId = Guid.NewGuid(),
        CreatedAtUtc = UtcNow,
        UpdatedAtUtc = UtcNow,
    };

    private static ProtectionAdminOperationStep CreateStep(Guid operationId, int orderIndex) => new()
    {
        Id = Guid.NewGuid(),
        ProtectionAdminOperationId = operationId,
        StepType = (ProtectionAdminStepType)orderIndex,
        Status = ProtectionAdminStepStatus.Pending,
        OrderIndex = orderIndex,
        RetryDisposition = ProtectionRetryDisposition.NotApplicable,
    };

    private static readonly DateTime UtcNow =
        new(2026, 9, 5, 9, 0, 0, DateTimeKind.Utc);
}
