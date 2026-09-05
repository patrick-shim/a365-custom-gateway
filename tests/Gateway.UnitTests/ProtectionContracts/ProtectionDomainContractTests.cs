using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.UnitTests.ProtectionContracts;

public sealed class ProtectionDomainContractTests
{
    [Fact]
    public void DirectoryIdentifiers_WithEqualGuidValues_RemainDistinctTypes()
    {
        var value = Guid.NewGuid();

        var blueprintObjectId = new BlueprintObjectId(value);
        var blueprintApplicationId = new BlueprintApplicationId(value);
        var applicationClientId = new ApplicationClientId(value);
        var servicePrincipalObjectId = new ServicePrincipalObjectId(value);
        var childAgentIdentityObjectId = new ChildAgentIdentityObjectId(value);

        blueprintObjectId.GetType().Should().NotBe(blueprintApplicationId.GetType());
        blueprintApplicationId.GetType().Should().NotBe(applicationClientId.GetType());
        applicationClientId.GetType().Should().NotBe(servicePrincipalObjectId.GetType());
        servicePrincipalObjectId.GetType().Should().NotBe(childAgentIdentityObjectId.GetType());
    }

    [Fact]
    public void RegistrationProvisioningWorkflowV3_RemainsUnchanged()
    {
        ProvisioningWorkflow.CurrentVersion.Should().Be(3);
        ProvisioningWorkflow.CurrentSteps.Should().Equal(
            ProvisioningStepType.ResolveBlueprint,
            ProvisioningStepType.EnsureBlueprintPrincipal,
            ProvisioningStepType.ConfigureGatewayFederation,
            ProvisioningStepType.CreateAgentIdentity,
            ProvisioningStepType.AssignAgent365Access,
            ProvisioningStepType.RegisterAgent,
            ProvisioningStepType.VerifyAgent365Connection);
    }

    [Fact]
    public void SnapshotGeneration_ExpiresAtItsExactBoundary()
    {
        var expiresAtUtc = new DateTime(2026, 9, 5, 12, 0, 0, DateTimeKind.Utc);
        var generation = new PurviewSensitiveInformationTypeSnapshotGeneration
        {
            Id = new SensitiveInformationTypeSnapshotGenerationId(Guid.NewGuid()),
            TenantId = new EntraTenantId(Guid.NewGuid()),
            RetrievedAtUtc = expiresAtUtc.AddMinutes(-10),
            ExpiresAtUtc = expiresAtUtc
        };

        generation.IsExpired(expiresAtUtc.AddTicks(-1)).Should().BeFalse();
        generation.IsExpired(expiresAtUtc).Should().BeTrue();
    }

    [Fact]
    public void KnowYourDataConfiguration_AlwaysUsesFixedGroupAndApplicationPlane()
    {
        var configuration = new PurviewKnowYourDataConfiguration();

        configuration.ScopeType.Should().Be(PurviewPolicyScopeType.Group);
        configuration.GroupId.Should().Be(PurviewPolicyLocationContract.EnterpriseAiAppsGroupId);
        configuration.EnforcementPlane.Should().Be(PurviewEnforcementPlane.Application);
    }

    [Fact]
    public void DlpProfile_IsReadyOnlyForItsExactBlueprintAndCompleteReadiness()
    {
        var now = new DateTime(2026, 9, 5, 12, 0, 0, DateTimeKind.Utc);
        var blueprintApplicationId = new BlueprintApplicationId(Guid.NewGuid());
        var profile = new PurviewDlpProfile
        {
            Id = new PurviewDlpProfileId(Guid.NewGuid()),
            BlueprintApplicationId = blueprintApplicationId,
            Status = PurviewDlpProfileStatus.Ready,
            SensitiveInformationTypeSnapshotExpiresAtUtc = now.AddHours(1),
            DlpPolicyProviderId = "policy-id",
            DlpRuleProviderId = "rule-id",
            LastReadbackAtUtc = now.AddMinutes(-5),
            PropagationVerifiedAtUtc = now.AddMinutes(-4),
            TokenRolesVerifiedAtUtc = now.AddMinutes(-3),
            RuntimeAllowVerifiedAtUtc = now.AddMinutes(-2),
            RuntimeBlockVerifiedAtUtc = now.AddMinutes(-1),
            Readiness = new ProtectionReadiness(
                ProtectionCapabilityStatus.Installed,
                ProtectionReadbackStatus.Ready,
                ProtectionPropagationStatus.Ready,
                ProtectionTokenRoleStatus.Ready,
                ProtectionRuntimeVerdictStatus.Ready)
        };

        profile.IsExactlyReadyFor(blueprintApplicationId, now).Should().BeTrue();
        profile.IsExactlyReadyFor(
            new BlueprintApplicationId(Guid.NewGuid()),
            now).Should().BeFalse();

        profile.Readiness = profile.Readiness with
        {
            TokenRoles = ProtectionTokenRoleStatus.MissingRequiredRoles
        };

        profile.IsExactlyReadyFor(blueprintApplicationId, now).Should().BeFalse();
    }

    [Fact]
    public void EffectivePurviewEnablement_FailsClosedWithoutExactReadyProfile()
    {
        var now = new DateTime(2026, 9, 5, 12, 0, 0, DateTimeKind.Utc);
        var blueprintApplicationId = new BlueprintApplicationId(Guid.NewGuid());
        var requestedProfileId = new PurviewDlpProfileId(Guid.NewGuid());
        var profile = new PurviewDlpProfile
        {
            Id = requestedProfileId,
            BlueprintApplicationId = blueprintApplicationId,
            Status = PurviewDlpProfileStatus.Ready,
            SensitiveInformationTypeSnapshotExpiresAtUtc = now.AddMinutes(30),
            DlpPolicyProviderId = "policy-id",
            DlpRuleProviderId = "rule-id",
            LastReadbackAtUtc = now.AddMinutes(-5),
            PropagationVerifiedAtUtc = now.AddMinutes(-4),
            TokenRolesVerifiedAtUtc = now.AddMinutes(-3),
            RuntimeAllowVerifiedAtUtc = now.AddMinutes(-2),
            RuntimeBlockVerifiedAtUtc = now.AddMinutes(-1),
            Readiness = ProtectionReadiness.Ready
        };

        PurviewEffectiveProtection.Evaluate(
                true,
                blueprintApplicationId,
                requestedProfileId,
                profile,
                now)
            .IsEnabled.Should().BeTrue();

        PurviewEffectiveProtection.Evaluate(
                true,
                blueprintApplicationId,
                new PurviewDlpProfileId(Guid.NewGuid()),
                profile,
                now)
            .Should().BeEquivalentTo(new
            {
                IsRequested = true,
                IsEnabled = false,
                Status = PurviewEffectiveEnablementStatus.ProfileMismatch
            });
    }

    [Fact]
    public void ProtectionIdempotencyKey_RequiresCanonicalUuidVersion4()
    {
        var valid = Guid.Parse("00000000-0000-4000-8000-000000000001");
        var wrongVersion = Guid.Parse("00000000-0000-1000-8000-000000000001");

        new ProtectionIdempotencyKey(valid).Value.Should().Be(valid);

        var act = () => new ProtectionIdempotencyKey(wrongVersion);
        act.Should().Throw<ArgumentException>().WithMessage("*UUIDv4*");
    }

    [Fact]
    public void ProtectionAdminOperation_PreservesStableOrderedDistinctSteps()
    {
        var operation = new ProtectionAdminOperation();
        operation.AddStep(new ProtectionAdminOperationStep
        {
            Id = Guid.NewGuid(),
            OrderIndex = 1,
            StepType = ProtectionAdminStepType.DiscoverProviderState
        });
        operation.AddStep(new ProtectionAdminOperationStep
        {
            Id = Guid.NewGuid(),
            OrderIndex = 0,
            StepType = ProtectionAdminStepType.ValidateReviewedIntent
        });

        operation.OrderedSteps.Select(step => step.StepType).Should().ContainInOrder(
            ProtectionAdminStepType.ValidateReviewedIntent,
            ProtectionAdminStepType.DiscoverProviderState);

        var duplicateOrder = () => operation.AddStep(new ProtectionAdminOperationStep
        {
            Id = Guid.NewGuid(),
            OrderIndex = 1,
            StepType = ProtectionAdminStepType.RecordExactReadback
        });

        duplicateOrder.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ProtectionAdminOperation_ReportsRetryAndManualInterventionTruthfully()
    {
        var now = new DateTime(2026, 9, 5, 12, 0, 0, DateTimeKind.Utc);
        var operation = new ProtectionAdminOperation
        {
            Status = ProtectionAdminOperationStatus.Failed,
            RetryDisposition = ProtectionRetryDisposition.Retryable,
            AttemptCount = 1,
            MaximumAttempts = 3,
            NextAttemptAtUtc = now
        };

        operation.CanRetryAt(now).Should().BeTrue();

        operation.Status = ProtectionAdminOperationStatus.RequiresManualIntervention;
        operation.RetryDisposition = ProtectionRetryDisposition.RequiresManualIntervention;

        operation.CanRetryAt(now).Should().BeFalse();
        operation.RequiresManualIntervention.Should().BeTrue();
    }

    [Fact]
    public void ConfirmationVerifier_StoresOnlyDefensiveSaltedVerifierMetadata()
    {
        var salt = new byte[] { 1, 2, 3 };
        var hash = new byte[] { 4, 5, 6 };
        var verifier = new ProtectionConfirmationVerifier(
            Guid.NewGuid(),
            Guid.NewGuid(),
            1,
            "PBKDF2-SHA256",
            salt,
            hash,
            DateTime.UtcNow.AddMinutes(5));

        salt[0] = 9;
        hash[0] = 9;

        verifier.VerifierSalt.ToArray().Should().Equal(1, 2, 3);
        verifier.VerifierHash.ToArray().Should().Equal(4, 5, 6);
        typeof(ProtectionConfirmationVerifier)
            .GetProperties()
            .Select(property => property.Name)
            .Should().NotContain(name =>
                name.Equals("Token", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("ClearText", StringComparison.OrdinalIgnoreCase));
    }
}
