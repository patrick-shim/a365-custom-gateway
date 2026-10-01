using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.TestSupport;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

public sealed partial class M4ProtectionAdministrationTests
{
    [Theory]
    [InlineData(PurviewPolicyMode.Enforce)]
    [InlineData(PurviewPolicyMode.SimulationWithTips)]
    [InlineData(PurviewPolicyMode.SimulationWithoutTips)]
    [InlineData(PurviewPolicyMode.Disabled)]
    public async Task Reviewed_reconciliation_can_recover_an_expired_catalog_without_recreating_a_profile(PurviewPolicyMode mode)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedReconciliationAsync(database, mode);
        var freshInventoryId = await RefreshReconciliationInventoryAsync(database);
        PurviewDlpProfile before;
        string[] agentChoices;
        await using (var context = database.CreateContext())
        {
            before = await context.PurviewDlpProfiles.AsNoTracking().SingleAsync();
            agentChoices = (await context.AgentRegistrations.AsNoTracking().OrderBy(agent => agent.Id).ToArrayAsync())
                .Select(agent => JsonSerializer.Serialize(agent.FeatureConfiguration)).ToArray();
        }
        var (review, etag) = await ReviewReconciliationAsync(database, seed);
        Assert.Equal(freshInventoryId, review.Review.InventoryGenerationId);
        Assert.All(review.Review.SensitiveInformationTypes!, value => Assert.Equal(freshInventoryId, value.InventoryGenerationId));
        Assert.Contains("read-only reconciliation", review.Review.ReadinessDisclaimer);
        Assert.Contains("does not create or change Microsoft policies", review.Review.ReadinessDisclaimer);
        await using (var untouched = database.CreateContext())
        {
            Assert.Equal(seed.InventoryId, (await untouched.PurviewDlpProfiles.SingleAsync()).InventoryGenerationId.Value);
            Assert.Empty(await untouched.OutboxMessages.ToArrayAsync());
        }
        var confirmation = await ConfirmAsync(database, seed, review);
        var request = new ReconcilePurviewDlpProfileRequest(confirmation.ConfirmationTokenId,
            confirmation.ConfirmationToken, Guid.NewGuid(), etag);
        await using (var context = database.CreateContext())
        await using (var transaction = await context.Database.BeginTransactionAsync())
        {
            var accepted = await Mutations(context).Handle(new ReconcilePurviewDlpProfileCommand(seed.Actor, seed.ProfileId, request), default);
            Assert.Equal(review.ReviewTokenId, accepted.OperationId);
            await transaction.CommitAsync();
        }
        await using (var replay = database.CreateContext())
        {
            var accepted = await Mutations(replay).Handle(new ReconcilePurviewDlpProfileCommand(seed.Actor, seed.ProfileId, request), default);
            Assert.Equal(review.ReviewTokenId, accepted.OperationId);
        }
        await using var verify = database.CreateContext();
        var saved = await verify.PurviewDlpProfiles.SingleAsync();
        Assert.Equal(before.Id, saved.Id);
        Assert.Equal(freshInventoryId, saved.InventoryGenerationId.Value);
        Assert.Equal(TestData.Now.AddMinutes(15), saved.SensitiveInformationTypeSnapshotExpiresAtUtc);
        Assert.Equal(before.BlueprintApplicationId, saved.BlueprintApplicationId);
        Assert.Equal(before.DisplayName, saved.DisplayName);
        Assert.Equal(before.DlpPolicyProviderId, saved.DlpPolicyProviderId);
        Assert.Equal(before.DlpRuleProviderId, saved.DlpRuleProviderId);
        Assert.Equal(before.LastReadbackAtUtc, saved.LastReadbackAtUtc);
        Assert.Equal(mode, saved.EffectivePolicyMode);
        Assert.Equal(before.NormalizedSensitiveInformationTypes, saved.NormalizedSensitiveInformationTypes);
        Assert.Equal(before.Activities, saved.Activities);
        Assert.Equal(before.Actions, saved.Actions);
        Assert.Equal(PurviewDlpProfileStatus.Pending, saved.Status);
        Assert.Equal(ProtectionReadbackStatus.Pending, saved.Readiness.Readback);
        Assert.Null(saved.RuntimeBehaviorSuiteHash);
        Assert.Null(saved.RuntimeBehaviorVerifiedUntilUtc);
        Assert.Null(saved.RuntimeBehaviorCertificationOperationId);
        Assert.Null(saved.RuntimeAllowVerifiedAtUtc);
        Assert.Null(saved.RuntimeBlockVerifiedAtUtc);
        Assert.False(saved.Readiness.IsReady);
        Assert.Equal(agentChoices, (await verify.AgentRegistrations.OrderBy(agent => agent.Id).ToArrayAsync())
            .Select(agent => JsonSerializer.Serialize(agent.FeatureConfiguration)).ToArray());
        Assert.Single(await verify.OutboxMessages.ToArrayAsync());
        Assert.Equal(ProtectionAdminOperationType.ReconcileDlpProfile, (await verify.ProtectionAdminOperations.SingleAsync()).Type);
    }

    [Theory]
    [InlineData("renamed-selection")]
    [InlineData("missing-selection")]
    [InlineData("expired-inventory")]
    [InlineData("legacy-thresholds")]
    public async Task Reconciliation_refresh_cannot_replace_selection_identity_or_invent_legacy_thresholds(string invalid)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedReconciliationAsync(database, PurviewPolicyMode.Enforce);
        var freshId = await RefreshReconciliationInventoryAsync(database);
        await using (var context = database.CreateContext())
        {
            var profile = await context.PurviewDlpProfiles.SingleAsync();
            if (invalid == "legacy-thresholds")
                profile.SensitiveInformationTypes = [new(seed.FirstType, "First synthetic classifier", 1, -1, null, 100)];
            else
            {
                var current = await context.Set<PurviewSensitiveInformationTypeSnapshotGeneration>()
                    .Include(value => value.Items).SingleAsync(value => value.Id != profile.InventoryGenerationId);
                Assert.Equal(freshId, current.Id.Value);
                if (invalid == "renamed-selection")
                    current.Items.Single(value => value.SensitiveInformationTypeId.Value == seed.SecondType).ExactName = "Changed classifier";
                else if (invalid == "missing-selection")
                {
                    var missing = current.Items.Single(value => value.SensitiveInformationTypeId.Value == seed.SecondType);
                    context.Remove(missing);
                    current.Items.Remove(missing);
                    current.ItemCount--;
                }
                else
                {
                    current.RetrievedAtUtc = TestData.Now.AddMinutes(-15);
                    current.ExpiresAtUtc = TestData.Now;
                }
            }
            await context.SaveChangesAsync();
        }
        var error = await Assert.ThrowsAsync<DomainException>(() => ReviewReconciliationAsync(database, seed));
        Assert.Equal(invalid == "legacy-thresholds" ? ErrorCodes.PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED : ErrorCodes.PURVIEW_INVENTORY_STALE,
            error.ErrorCode);
        await using var verify = database.CreateContext();
        Assert.Equal(seed.InventoryId, (await verify.PurviewDlpProfiles.SingleAsync()).InventoryGenerationId.Value);
        Assert.Empty(await verify.ProtectionAdminOperations.ToArrayAsync());
        Assert.Empty(await verify.OutboxMessages.ToArrayAsync());
    }

    [Theory]
    [InlineData("profile")]
    [InlineData("inventory")]
    [InlineData("inventory-expired")]
    [InlineData("renamed-selection")]
    public async Task Reconciliation_refresh_rejects_drift_after_confirmation_and_rolls_back_token_consumption(string changed)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedReconciliationAsync(database, PurviewPolicyMode.Enforce);
        await RefreshReconciliationInventoryAsync(database);
        var (review, etag) = await ReviewReconciliationAsync(database, seed);
        var confirmation = await ConfirmAsync(database, seed, review);
        await using (var context = database.CreateContext())
        {
            if (changed == "profile")
                (await context.PurviewDlpProfiles.SingleAsync()).DisplayName = "Concurrent reviewed policy";
            else if (changed == "inventory")
                (await context.PurviewTenantConnections.SingleAsync()).ActiveInventoryGenerationId = new(seed.InventoryId);
            else
            {
                var connection = await context.PurviewTenantConnections.SingleAsync();
                var inventory = await context.Set<PurviewSensitiveInformationTypeSnapshotGeneration>()
                    .Include(value => value.Items).SingleAsync(value => value.Id == connection.ActiveInventoryGenerationId);
                if (changed == "renamed-selection")
                    inventory.Items.Single(value => value.SensitiveInformationTypeId.Value == seed.SecondType).ExactName = "Changed after confirmation";
                else
                {
                    inventory.RetrievedAtUtc = TestData.Now.AddMinutes(-15);
                    inventory.ExpiresAtUtc = TestData.Now;
                }
            }
            await context.SaveChangesAsync();
        }
        await using (var context = database.CreateContext())
        await using (var transaction = await context.Database.BeginTransactionAsync())
        {
            var command = new ReconcilePurviewDlpProfileCommand(seed.Actor, seed.ProfileId,
                new(confirmation.ConfirmationTokenId, confirmation.ConfirmationToken, Guid.NewGuid(), etag));
            if (changed == "profile")
                await Assert.ThrowsAsync<PreconditionFailedException>(() => Mutations(context).Handle(command, default));
            else
                await Assert.ThrowsAsync<DomainException>(() => Mutations(context).Handle(command, default));
            await transaction.RollbackAsync();
        }
        await using var verify = database.CreateContext();
        Assert.Equal(seed.InventoryId, (await verify.PurviewDlpProfiles.SingleAsync()).InventoryGenerationId.Value);
        Assert.NotNull((await verify.PurviewDlpProfiles.SingleAsync()).RuntimeBehaviorSuiteHash);
        Assert.Null((await verify.ProtectionAdminOperations.SingleAsync()).ConfirmationVerifier!.ConsumedAtUtc);
        Assert.Empty(await verify.OutboxMessages.ToArrayAsync());
    }

    private static async Task<Seed> SeedReconciliationAsync(LocalSqlDatabase database, PurviewPolicyMode mode)
    {
        var seed = await SeedAsync(database);
        await using var context = database.CreateContext();
        var profile = await context.PurviewDlpProfiles.SingleAsync();
        profile.PolicyMode = mode;
        profile.Mode = mode.ToLegacy();
        profile.Activities = [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText];
        profile.Actions = [new(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)];
        profile.SensitiveInformationTypes =
        [
            new(seed.FirstType, "First synthetic classifier", 2, 3, 80, 95),
            new(seed.SecondType, "Second synthetic classifier", 1, -1, 65, 100)
        ];
        await context.SaveChangesAsync();
        return seed;
    }

    private static async Task<Guid> RefreshReconciliationInventoryAsync(LocalSqlDatabase database)
    {
        await using var context = database.CreateContext();
        var previous = await context.Set<PurviewSensitiveInformationTypeSnapshotGeneration>().Include(value => value.Items).SingleAsync();
        previous.RetrievedAtUtc = TestData.Now.AddMinutes(-15);
        previous.ExpiresAtUtc = TestData.Now;
        var profile = await context.PurviewDlpProfiles.SingleAsync();
        profile.SensitiveInformationTypeSnapshotExpiresAtUtc = TestData.Now;
        var fresh = new PurviewSensitiveInformationTypeSnapshotGeneration
        {
            Id = new(Guid.NewGuid()), PurviewTenantConnectionId = previous.PurviewTenantConnectionId, TenantId = previous.TenantId,
            RetrievedAtUtc = TestData.Now, CreatedAtUtc = TestData.Now, ExpiresAtUtc = TestData.Now.AddMinutes(15),
            ItemCount = previous.ItemCount
        };
        fresh.Items = previous.Items.Select(item => new PurviewSensitiveInformationTypeSnapshot
        {
            Id = Guid.NewGuid(), GenerationId = fresh.Id, SensitiveInformationTypeId = item.SensitiveInformationTypeId,
            ExactName = item.ExactName, Publisher = "Synthetic fixture", SortOrder = item.SortOrder
        }).ToList();
        context.Add(fresh);
        await context.SaveChangesAsync();
        var connection = await context.PurviewTenantConnections.SingleAsync();
        connection.ActiveInventoryGenerationId = fresh.Id;
        connection.ExpiresAtUtc = fresh.ExpiresAtUtc;
        await context.SaveChangesAsync();
        return fresh.Id.Value;
    }

    private static async Task<(ProtectionOperationReviewResponse Review, string Etag)> ReviewReconciliationAsync(
        LocalSqlDatabase database, Seed seed)
    {
        await using var context = database.CreateContext();
        var profile = await context.PurviewDlpProfiles.SingleAsync();
        var etag = Convert.ToBase64String(profile.RowVersion);
        var review = await Reviews(context, seed).Handle(new ReviewReconcilePurviewDlpProfileCommand(seed.Actor,
            seed.ProfileId, new(seed.ProfileId, etag), Guid.NewGuid()), default);
        return (review, etag);
    }
}
