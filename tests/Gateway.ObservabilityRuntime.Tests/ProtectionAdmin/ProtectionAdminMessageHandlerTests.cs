using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Gateway.Provisioning.Worker;
using Gateway.Purview;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using NSubstitute;

namespace Gateway.ObservabilityRuntime.Tests.ProtectionAdmin;

public sealed class ProtectionAdminMessageHandlerTests
{
    [Fact]
    public async Task HandleAsync_FullDlpAndExplicitRuntimeWorkflowsReachReadyInOrder()
    {
        var fixture = new HandlerFixture();
        var readback = fixture.CreateDlpReadback();
        fixture.SettingsProvider.VerifyDlpProfileAsync(
                Arg.Any<PurviewDlpProfileIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewSettingsOperationResult<PurviewDlpProfileReadback>(
                PurviewSettingsOperationDisposition.ExactReadback,
                readback,
                null));
        fixture.SettingsProvider.EnsureDlpProfileAsync(
                Arg.Any<PurviewDlpProfileIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewSettingsOperationResult<PurviewDlpProfileReadback>(
                PurviewSettingsOperationDisposition.AlreadyExact,
                readback,
                null));
        fixture.RuntimeValidator.ProbePropagationAsync(
                Arg.Any<Guid>(),
                ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow.AddMinutes(-2)));
        fixture.TokenRoleAttestor.AttestAsync(
                fixture.TenantId.Value,
                Arg.Any<CancellationToken>())
            .Returns(new PurviewTokenRoleAttestation(
                ProtectionTokenRoleStatus.Ready,
                new DateTimeOffset(UtcNow.AddMinutes(-1), TimeSpan.Zero),
                new DateTimeOffset(UtcNow.AddMinutes(30), TimeSpan.Zero),
                null));
        fixture.RuntimeValidator.ValidateAllowAsync(
                Arg.Any<Guid>(),
                ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow.AddMinutes(-1)));
        fixture.RuntimeValidator.ValidateBlockAsync(
                Arg.Any<Guid>(),
                ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow));

        var authoring = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 0);
        fixture.Arrange(authoring);
        for (var index = 0; index < ProtectionAdminWorkflow.CurrentSteps.Count; index++)
        {
            var result = await fixture.Handler.HandleAsync(
                nameof(ProtectionAdminOperationMessage),
                CreatePayload(authoring, index),
                CancellationToken.None);
            result.ShouldDeadLetter.Should().BeFalse();
        }

        authoring.Status.Should().Be(ProtectionAdminOperationStatus.Completed);
        authoring.RequiredAction.Should().Be("ValidateRuntime");
        authoring.OrderedSteps.Select(step => step.Status).Should().Equal(
            ProtectionAdminStepStatus.Completed,
            ProtectionAdminStepStatus.Completed,
            ProtectionAdminStepStatus.Completed,
            ProtectionAdminStepStatus.Completed,
            ProtectionAdminStepStatus.Completed,
            ProtectionAdminStepStatus.Completed,
            ProtectionAdminStepStatus.Skipped,
            ProtectionAdminStepStatus.Completed);
        fixture.Profile.Status.Should().Be(PurviewDlpProfileStatus.PendingPropagation);
        fixture.Profile.Readiness.RuntimeVerdict.Should()
            .Be(ProtectionRuntimeVerdictStatus.NotChecked);

        var runtime = fixture.CreateOperation(
            ProtectionAdminOperationType.ValidateDlpRuntime,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 0);
        fixture.Arrange(runtime);
        for (var index = 0; index < ProtectionAdminWorkflow.CurrentSteps.Count; index++)
        {
            var result = await fixture.Handler.HandleAsync(
                nameof(ProtectionAdminOperationMessage),
                CreatePayload(runtime, index),
                CancellationToken.None);
            result.ShouldDeadLetter.Should().BeFalse();
        }

        runtime.Status.Should().Be(ProtectionAdminOperationStatus.Completed);
        fixture.Profile.Status.Should().Be(PurviewDlpProfileStatus.Ready);
        fixture.Profile.Readiness.Should().Be(ProtectionReadiness.Ready);
    }

    [Fact]
    public async Task HandleAsync_DlpMutationPersistsExactReadbackAndDuplicateDoesNotRepeatProvider()
    {
        var fixture = new HandlerFixture();
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 2);
        fixture.Arrange(operation);
        fixture.SettingsProvider.EnsureDlpProfileAsync(
                Arg.Any<PurviewDlpProfileIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewSettingsOperationResult<PurviewDlpProfileReadback>(
                PurviewSettingsOperationDisposition.MutatedAndVerified,
                fixture.CreateDlpReadback(),
                null));

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);
        var duplicate = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        duplicate.ShouldDeadLetter.Should().BeFalse();
        operation.OrderedSteps[2].Status.Should().Be(ProtectionAdminStepStatus.Completed);
        fixture.Profile.DlpPolicyProviderId.Should().Be("policy-exact");
        fixture.Profile.DlpRuleProviderId.Should().Be("rule-exact");
        fixture.Profile.Status.Should().Be(PurviewDlpProfileStatus.PendingPropagation);
        fixture.Profile.Readiness.Readback.Should().Be(ProtectionReadbackStatus.Ready);
        fixture.Profile.Readiness.IsReady.Should().BeFalse();
        fixture.AddedOutboxMessages.Should().ContainSingle();
        JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
                fixture.AddedOutboxMessages[0].Payload,
                JsonSerializerOptions.Web)!
            .ExpectedStepIndex.Should().Be(3);
        await fixture.SettingsProvider.Received(1).EnsureDlpProfileAsync(
            Arg.Is<PurviewDlpProfileIntent>(intent =>
                intent.BlueprintApplicationId == fixture.Profile.BlueprintApplicationId.Value &&
                intent.RecoveryPoint == PurviewDlpMutationRecoveryPoint.None &&
                intent.Actions.SequenceEqual(fixture.Profile.Actions)),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_RedeliveredRunningDlpMutationUsesGetOnlyRecoveryPoint()
    {
        var fixture = new HandlerFixture();
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 2);
        operation.Status = ProtectionAdminOperationStatus.Running;
        operation.OrderedSteps[2].Status = ProtectionAdminStepStatus.Running;
        operation.OrderedSteps[2].AttemptCount = 1;
        fixture.Arrange(operation);
        fixture.SettingsProvider.EnsureDlpProfileAsync(
                Arg.Any<PurviewDlpProfileIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewSettingsOperationResult<PurviewDlpProfileReadback>(
                PurviewSettingsOperationDisposition.RequiresManualIntervention,
                null,
                "PURVIEW_DLP_RULE_PRIOR_MUTATION_UNRESOLVED"));

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be("PURVIEW_DLP_RULE_PRIOR_MUTATION_UNRESOLVED");
        operation.Status.Should().Be(ProtectionAdminOperationStatus.RequiresManualIntervention);
        operation.RequiredAction.Should().Be("Reconcile");
        operation.OrderedSteps[2].Status.Should()
            .Be(ProtectionAdminStepStatus.RequiresManualIntervention);
        fixture.AddedOutboxMessages.Should().BeEmpty();
        await fixture.SettingsProvider.Received(1).EnsureDlpProfileAsync(
            Arg.Is<PurviewDlpProfileIntent>(intent =>
                intent.RecoveryPoint ==
                PurviewDlpMutationRecoveryPoint.RuleCreationOutcomeUnknown),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_DlpMutationRequiresASeparateExactReadbackStep()
    {
        var fixture = new HandlerFixture();
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 2);
        fixture.Arrange(operation);
        var readback = fixture.CreateDlpReadback();
        fixture.SettingsProvider.EnsureDlpProfileAsync(
                Arg.Any<PurviewDlpProfileIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewSettingsOperationResult<PurviewDlpProfileReadback>(
                PurviewSettingsOperationDisposition.MutatedAndVerified,
                readback,
                null));
        fixture.SettingsProvider.VerifyDlpProfileAsync(
                Arg.Any<PurviewDlpProfileIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewSettingsOperationResult<PurviewDlpProfileReadback>(
                PurviewSettingsOperationDisposition.ExactReadback,
                readback,
                null));

        var mutation = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);
        var exactReadback = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 3),
            CancellationToken.None);

        mutation.ShouldDeadLetter.Should().BeFalse();
        exactReadback.ShouldDeadLetter.Should().BeFalse();
        operation.OrderedSteps[2].Status.Should().Be(ProtectionAdminStepStatus.Completed);
        operation.OrderedSteps[3].Status.Should().Be(ProtectionAdminStepStatus.Completed);
        operation.OrderedSteps[3].ReadbackReferenceId.Should()
            .Be(fixture.Profile.Id.Value);
        await fixture.SettingsProvider.Received(1).EnsureDlpProfileAsync(
            Arg.Any<PurviewDlpProfileIntent>(),
            Arg.Any<CancellationToken>());
        await fixture.SettingsProvider.Received(1).VerifyDlpProfileAsync(
            Arg.Any<PurviewDlpProfileIntent>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_RuntimeValidationSetsReadyOnlyAfterAllowAndBlock()
    {
        var fixture = new HandlerFixture();
        fixture.Profile.LastReadbackAtUtc = UtcNow.AddMinutes(-4);
        fixture.Profile.PropagationVerifiedAtUtc = UtcNow.AddMinutes(-3);
        fixture.Profile.TokenRolesVerifiedAtUtc = UtcNow.AddMinutes(-2);
        fixture.Profile.Readiness = new ProtectionReadiness(
            ProtectionCapabilityStatus.Installed,
            ProtectionReadbackStatus.Ready,
            ProtectionPropagationStatus.Ready,
            ProtectionTokenRoleStatus.Ready,
            ProtectionRuntimeVerdictStatus.NotChecked);
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ValidateDlpRuntime,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 6);
        fixture.Arrange(operation);
        fixture.RuntimeValidator.ValidateAllowAsync(
                operation.Id,
                operation.ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow.AddMinutes(-1)));
        fixture.RuntimeValidator.ValidateBlockAsync(
                operation.Id,
                operation.ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow));

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 6),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        fixture.Profile.RuntimeAllowVerifiedAtUtc.Should().Be(UtcNow.AddMinutes(-1));
        fixture.Profile.RuntimeBlockVerifiedAtUtc.Should().Be(UtcNow);
        fixture.Profile.Status.Should().Be(PurviewDlpProfileStatus.Ready);
        fixture.Profile.Readiness.Should().Be(ProtectionReadiness.Ready);
        operation.OrderedSteps[6].Status.Should().Be(ProtectionAdminStepStatus.Completed);
        fixture.AddedOutboxMessages.Should().ContainSingle();
        await fixture.RuntimeValidator.Received(1).ValidateAllowAsync(
            operation.Id,
            operation.ActorObjectId,
            fixture.Profile,
            Arg.Any<CancellationToken>());
        await fixture.RuntimeValidator.Received(1).ValidateBlockAsync(
            operation.Id,
            operation.ActorObjectId,
            fixture.Profile,
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_DlpCreationAttestsPropagationAndTokenBeforeExplicitRuntime()
    {
        var fixture = new HandlerFixture();
        fixture.Profile.DlpPolicyProviderId = "policy-exact";
        fixture.Profile.DlpRuleProviderId = "rule-exact";
        fixture.Profile.LastReadbackAtUtc = UtcNow.AddMinutes(-4);
        fixture.Profile.Readiness = fixture.Profile.Readiness with
        {
            Readback = ProtectionReadbackStatus.Ready
        };
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 4);
        fixture.Arrange(operation);
        fixture.RuntimeValidator.ProbePropagationAsync(
                operation.Id,
                operation.ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow.AddMinutes(-2)));
        fixture.TokenRoleAttestor.AttestAsync(
                fixture.TenantId.Value,
                Arg.Any<CancellationToken>())
            .Returns(new PurviewTokenRoleAttestation(
                ProtectionTokenRoleStatus.Ready,
                new DateTimeOffset(UtcNow.AddMinutes(-1), TimeSpan.Zero),
                new DateTimeOffset(UtcNow.AddMinutes(30), TimeSpan.Zero),
                null));

        var propagation = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 4),
            CancellationToken.None);
        var tokenRoles = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 5),
            CancellationToken.None);
        var runtimeSkip = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 6),
            CancellationToken.None);

        propagation.ShouldDeadLetter.Should().BeFalse();
        tokenRoles.ShouldDeadLetter.Should().BeFalse();
        runtimeSkip.ShouldDeadLetter.Should().BeFalse();
        fixture.Profile.Readiness.Propagation.Should().Be(ProtectionPropagationStatus.Ready);
        fixture.Profile.Readiness.TokenRoles.Should().Be(ProtectionTokenRoleStatus.Ready);
        fixture.Profile.Readiness.RuntimeVerdict.Should()
            .Be(ProtectionRuntimeVerdictStatus.NotChecked);
        fixture.Profile.Status.Should().Be(PurviewDlpProfileStatus.PendingPropagation);
        await fixture.RuntimeValidator.DidNotReceiveWithAnyArgs()
            .ValidateAllowAsync(default, default!, default!, default);
        await fixture.RuntimeValidator.DidNotReceiveWithAnyArgs()
            .ValidateBlockAsync(default, default!, default!, default);
    }

    [Fact]
    public async Task HandleAsync_RuntimeBlockFailureNeverMarksProfileReady()
    {
        var fixture = new HandlerFixture();
        fixture.Profile.LastReadbackAtUtc = UtcNow.AddMinutes(-4);
        fixture.Profile.PropagationVerifiedAtUtc = UtcNow.AddMinutes(-3);
        fixture.Profile.TokenRolesVerifiedAtUtc = UtcNow.AddMinutes(-2);
        fixture.Profile.Readiness = new ProtectionReadiness(
            ProtectionCapabilityStatus.Installed,
            ProtectionReadbackStatus.Ready,
            ProtectionPropagationStatus.Ready,
            ProtectionTokenRoleStatus.Ready,
            ProtectionRuntimeVerdictStatus.NotChecked);
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ValidateDlpRuntime,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 6);
        fixture.Arrange(operation);
        fixture.RuntimeValidator.ValidateAllowAsync(
                operation.Id,
                operation.ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Ready(UtcNow.AddMinutes(-1)));
        fixture.RuntimeValidator.ValidateBlockAsync(
                operation.Id,
                operation.ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Failed(
                UtcNow,
                "PURVIEW_RUNTIME_BLOCK_NOT_OBSERVED"));

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 6),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        fixture.Profile.Status.Should().Be(PurviewDlpProfileStatus.VerificationFailed);
        fixture.Profile.Readiness.IsReady.Should().BeFalse();
        fixture.Profile.RuntimeAllowVerifiedAtUtc.Should().NotBeNull();
        fixture.Profile.RuntimeBlockVerifiedAtUtc.Should().BeNull();
        operation.Status.Should().Be(ProtectionAdminOperationStatus.RequiresManualIntervention);
    }

    [Fact]
    public async Task HandleAsync_ConnectionBecomesConnectedOnlyAfterTwoIndependentProviderReadbacks()
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.AuthorityKind = "InteractiveSubmissionUnverified";
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.ExpiresAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        var providerEvidence = fixture.CreateConnectionProviderEvidence(operation);
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(providerEvidence);

        var discovery = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);
        var duplicateDiscovery = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);
        var skippedMutation = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);
        var exactReadback = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 3),
            CancellationToken.None);
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.PendingVerification);
        for (var index = 4; index < ProtectionAdminWorkflow.CurrentSteps.Count; index++)
        {
            var completion = await fixture.Handler.HandleAsync(
                nameof(ProtectionAdminOperationMessage),
                CreatePayload(operation, expectedStepIndex: index),
                CancellationToken.None);
            completion.ShouldDeadLetter.Should().BeFalse();
        }

        discovery.ShouldDeadLetter.Should().BeFalse();
        duplicateDiscovery.ShouldDeadLetter.Should().BeFalse();
        skippedMutation.ShouldDeadLetter.Should().BeFalse();
        exactReadback.ShouldDeadLetter.Should().BeFalse();
        fixture.Connection.Status.Should().Be(PurviewTenantConnectionStatus.Connected);
        operation.Status.Should().Be(ProtectionAdminOperationStatus.Completed);
        fixture.Connection.LastVerifiedAtUtc.Should().Be(UtcNow);
        fixture.Connection.AuthorityApplicationId!.Value.Value.Should()
            .Be(providerEvidence.AuthorityApplicationId);
        fixture.Connection.ActiveInventoryGenerationId!.Value.Value.Should()
            .Be(providerEvidence.InventoryGenerationId);
        operation.ReadbackReferenceId.Should().Be(providerEvidence.InventoryGenerationId);
        operation.OrderedSteps[1].ReadbackReferenceId.Should()
            .Be(providerEvidence.InventoryGenerationId);
        operation.OrderedSteps[3].ReadbackReferenceId.Should()
            .Be(providerEvidence.InventoryGenerationId);
        fixture.AddedGenerations.Should().ContainSingle(generation =>
            generation.Id.Value == providerEvidence.InventoryGenerationId &&
            generation.TenantId == fixture.TenantId &&
            generation.Items.Count == providerEvidence.Items.Count);
        await fixture.ConnectionVerifier.Received(2).VerifyAsync(
            Arg.Is<PurviewConnectionVerificationRequest>(request =>
                request.OperationId == operation.Id &&
                request.TenantId == fixture.TenantId.Value &&
                request.AdministratorObjectId == Guid.Parse(ActorObjectId) &&
                request.ExpectedAuthorityApplicationId ==
                    AuthorityApplicationId &&
                request.ExpectedAuthorityServicePrincipalObjectId ==
                    AuthorityServicePrincipalObjectId &&
                request.ExpectedKeyVaultResourceId == KeyVaultResourceId &&
                request.ExpectedKeyVaultHost == KeyVaultHost &&
                request.ExpectedCertificateName == CertificateName &&
                request.ExpectedCertificateSecretUri == CertificateSecretUri),
            Arg.Any<CancellationToken>());
        await fixture.SettingsProvider.DidNotReceiveWithAnyArgs()
            .EnsureKnowYourDataAsync(default!, default);
        await fixture.SettingsProvider.DidNotReceiveWithAnyArgs()
            .EnsureDlpProfileAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_ConnectionProviderTenantMismatchFailsClosedWithUiActionCode()
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        var mismatched = fixture.CreateConnectionProviderEvidence(operation) with
        {
            TenantId = Guid.NewGuid()
        };
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(mismatched);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be("PURVIEW_CONNECTION_TENANT_MISMATCH");
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.VerificationFailed);
        fixture.Connection.ActiveInventoryGenerationId.Should().BeNull();
        operation.Status.Should()
            .Be(ProtectionAdminOperationStatus.RequiresManualIntervention);
        operation.RequiredAction.Should().Be("Retry");
        fixture.AddedGenerations.Should().BeEmpty();
    }

    [Fact]
    public async Task HandleAsync_ConnectionEvidenceDigestMismatchNeverStagesInventory()
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        var mismatched = fixture.CreateConnectionProviderEvidence(operation) with
        {
            EvidenceDigest =
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        };
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(mismatched);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(
            "PURVIEW_CONNECTION_EVIDENCE_DIGEST_MISMATCH");
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.VerificationFailed);
        fixture.AddedGenerations.Should().BeEmpty();
    }

    [Fact]
    public async Task HandleAsync_ConnectionProviderAdministratorMismatchFailsClosed()
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        var exact = fixture.CreateConnectionProviderEvidence(operation);
        var mismatched = PurviewConnectionVerificationEvidence.Create(
            exact.OperationId,
            exact.TenantId,
            Guid.NewGuid(),
            exact.AuthorityApplicationId,
            exact.AuthorityServicePrincipalObjectId,
            exact.KeyVaultResourceId,
            exact.KeyVaultHost,
            exact.CertificateName,
            exact.CertificateSecretUri,
            exact.ProviderCertificateSecretId,
            exact.ObservedAtUtc,
            exact.ExpiresAtUtc,
            exact.Items);
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(mismatched);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(
            "PURVIEW_CONNECTION_ADMINISTRATOR_MISMATCH");
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.VerificationFailed);
        fixture.AddedGenerations.Should().BeEmpty();
    }

    [Theory]
    [InlineData("Application")]
    [InlineData("ServicePrincipal")]
    [InlineData("KeyVaultResource")]
    [InlineData("KeyVaultHost")]
    [InlineData("CertificateName")]
    [InlineData("CertificateReference")]
    [InlineData("ProviderCertificate")]
    public async Task HandleAsync_ConnectionCapabilitySubstitutionNeverConnects(
        string substitution)
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        var exact = fixture.CreateConnectionProviderEvidence(operation);
        var substituted = substitution switch
        {
            "Application" => exact with
            {
                AuthorityApplicationId = Guid.NewGuid()
            },
            "ServicePrincipal" => exact with
            {
                AuthorityServicePrincipalObjectId = Guid.NewGuid()
            },
            "KeyVaultResource" => exact with
            {
                KeyVaultResourceId = KeyVaultResourceId.Replace(
                    "/vaults/gatewayvault",
                    "/vaults/othervault",
                    StringComparison.Ordinal)
            },
            "KeyVaultHost" => exact with
            {
                KeyVaultHost = "othervault.vault.azure.net"
            },
            "CertificateName" => exact with
            {
                CertificateName = "other-certificate"
            },
            "CertificateReference" => exact with
            {
                CertificateSecretUri =
                    new Uri("https://gatewayvault.vault.azure.net/secrets/other-certificate")
            },
            "ProviderCertificate" => exact with
            {
                ProviderCertificateSecretId =
                    new Uri("https://gatewayvault.vault.azure.net/secrets/other-certificate/version")
            },
            _ => throw new InvalidOperationException("Unknown substitution.")
        };
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(substituted);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(
            "PURVIEW_CONNECTION_CAPABILITY_BINDING_MISMATCH");
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.VerificationFailed);
        fixture.Connection.ActiveInventoryGenerationId.Should().BeNull();
        fixture.AddedGenerations.Should().BeEmpty();
    }

    [Theory]
    [InlineData(ProtectionCapabilityStatus.NotInstalled)]
    [InlineData(ProtectionCapabilityStatus.PendingPropagation)]
    [InlineData(ProtectionCapabilityStatus.Unavailable)]
    public async Task HandleAsync_ConnectionRequiresExactInstalledCapability(
        ProtectionCapabilityStatus status)
    {
        var fixture = new HandlerFixture();
        fixture.Capability.Status = status;
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be("PURVIEW_CAPABILITY_NOT_READY");
        fixture.Connection.Status.Should()
            .NotBe(PurviewTenantConnectionStatus.Connected);
        await fixture.ConnectionVerifier.DidNotReceiveWithAnyArgs()
            .VerifyAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_CapabilityCertificateDriftBeforeCompletionFailsClosed()
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        var exact = fixture.CreateConnectionProviderEvidence(operation);
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(exact);

        for (var index = 1; index <= 3; index++)
        {
            var result = await fixture.Handler.HandleAsync(
                nameof(ProtectionAdminOperationMessage),
                CreatePayload(operation, expectedStepIndex: index),
                CancellationToken.None);
            result.ShouldDeadLetter.Should().BeFalse();
        }
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.PendingVerification);
        fixture.Capability.ResourceIdentifiers =
            fixture.Capability.ResourceIdentifiers with
            {
                CertificateName = "substituted-certificate"
            };
        var completion = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 4),
            CancellationToken.None);

        completion.ShouldDeadLetter.Should().BeTrue();
        completion.DeadLetterReason.Should().Be(
            "PURVIEW_CAPABILITY_BINDING_INVALID");
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.PendingVerification);
        operation.Status.Should()
            .Be(ProtectionAdminOperationStatus.RequiresManualIntervention);
        operation.RequiredAction.Should().Be("Retry");
    }

    [Fact]
    public async Task HandleAsync_ConnectionReadTimeoutSchedulesReadbackFirstRetry()
    {
        var fixture = new HandlerFixture();
        fixture.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        fixture.Connection.ActiveInventoryGenerationId = null;
        fixture.Connection.AuthorizedAtUtc = null;
        fixture.Connection.LastVerifiedAtUtc = null;
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            fixture.Connection.Id,
            currentStepIndex: 1);
        fixture.Arrange(operation);
        fixture.ConnectionVerifier.VerifyAsync(
                Arg.Any<PurviewConnectionVerificationRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<PurviewConnectionVerificationEvidence>(
                new PurviewConnectionVerificationException(
                    "PURVIEW_CONNECTION_READ_TIMEOUT",
                    isTransient: true)));

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        fixture.Connection.Status.Should()
            .Be(PurviewTenantConnectionStatus.PendingVerification);
        operation.Status.Should().Be(ProtectionAdminOperationStatus.PendingPropagation);
        operation.RequiredAction.Should().Be("Retry");
        operation.OrderedSteps[1].Status.Should()
            .Be(ProtectionAdminStepStatus.PendingPropagation);
        fixture.AddedOutboxMessages.Should().ContainSingle(message =>
            message.MessageType == nameof(ProtectionAdminOperationMessage) &&
            message.NextRetryAtUtc == UtcNow.AddSeconds(1));
    }

    [Fact]
    public async Task HandleAsync_PendingPropagationSchedulesDurableDelayedPoll()
    {
        var fixture = new HandlerFixture();
        fixture.Profile.DlpPolicyProviderId = "policy-exact";
        fixture.Profile.DlpRuleProviderId = "rule-exact";
        fixture.Profile.LastReadbackAtUtc = UtcNow.AddMinutes(-4);
        fixture.Profile.Readiness = fixture.Profile.Readiness with
        {
            Readback = ProtectionReadbackStatus.Ready
        };
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 4);
        fixture.Arrange(operation);
        fixture.RuntimeValidator.ProbePropagationAsync(
                operation.Id,
                operation.ActorObjectId,
                fixture.Profile,
                Arg.Any<CancellationToken>())
            .Returns(PurviewRuntimeValidationResult.Pending(
                new DateTimeOffset(UtcNow, TimeSpan.Zero),
                "PURVIEW_SCOPE_MISSING"));

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 4),
            CancellationToken.None);
        var earlyDuplicate = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 4),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        earlyDuplicate.ShouldDeadLetter.Should().BeFalse();
        operation.Status.Should().Be(ProtectionAdminOperationStatus.PendingPropagation);
        operation.RequiredAction.Should().Be("WaitForPropagation");
        operation.OrderedSteps[4].Status.Should()
            .Be(ProtectionAdminStepStatus.PendingPropagation);
        fixture.AddedOutboxMessages.Should().ContainSingle(message =>
            message.NextRetryAtUtc == UtcNow.AddSeconds(1));
        await fixture.RuntimeValidator.Received(1).ProbePropagationAsync(
            operation.Id,
            operation.ActorObjectId,
            fixture.Profile,
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_UnconsumedConfirmationFailsBeforeProviderAccess()
    {
        var fixture = new HandlerFixture();
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 0);
        operation.ConfirmationVerifier = new ProtectionConfirmationVerifier(
            Guid.NewGuid(),
            Guid.NewGuid(),
            1,
            "PBKDF2-SHA256",
            [1],
            [2],
            UtcNow.AddMinutes(5));
        fixture.Arrange(operation);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 0),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(
            "PROTECTION_ADMIN_CONFIRMATION_NOT_CONSUMED");
        await fixture.SettingsProvider.DidNotReceiveWithAnyArgs()
            .EnsureDlpProfileAsync(default!, default);
        await fixture.RuntimeValidator.DidNotReceiveWithAnyArgs()
            .ProbePropagationAsync(default, default!, default!, default);
    }

    [Fact]
    public async Task HandleAsync_ChangedReviewedDlpIntentFailsBeforeProviderAccess()
    {
        var fixture = new HandlerFixture();
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 0);
        fixture.Profile.DisplayName = "Changed after review";
        fixture.Arrange(operation);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 0),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(
            "PROTECTION_ADMIN_REVIEWED_INTENT_CHANGED");
        await fixture.SettingsProvider.DidNotReceiveWithAnyArgs()
            .EnsureDlpProfileAsync(default!, default);
        await fixture.RuntimeValidator.DidNotReceiveWithAnyArgs()
            .ProbePropagationAsync(default, default!, default!, default);
    }

    [Fact]
    public async Task HandleAsync_KnowYourDataIntentKeepsFixedGroupIndependentOfBlueprint()
    {
        var fixture = new HandlerFixture();
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateKnowYourData,
            ProtectionAdminTargetType.KnowYourDataConfiguration,
            fixture.KnowYourData.Id,
            currentStepIndex: 2);
        fixture.Arrange(operation);
        fixture.SettingsProvider.EnsureKnowYourDataAsync(
                Arg.Any<PurviewKnowYourDataIntent>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var intent = call.Arg<PurviewKnowYourDataIntent>();
                return new PurviewSettingsOperationResult<PurviewKnowYourDataReadback>(
                    PurviewSettingsOperationDisposition.MutatedAndVerified,
                    fixture.CreateKnowYourDataReadback(intent),
                    null);
            });

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.SettingsProvider.Received(1).EnsureKnowYourDataAsync(
            Arg.Is<PurviewKnowYourDataIntent>(intent =>
                intent.TenantId == fixture.TenantId.Value &&
                !intent.PolicyName.Contains(
                    fixture.Profile.BlueprintApplicationId.Value.ToString("D"),
                    StringComparison.Ordinal)),
            Arg.Any<CancellationToken>());
        fixture.KnowYourData.GroupId.Should()
            .Be(PurviewPolicyLocationContract.EnterpriseAiAppsGroupId);
        fixture.KnowYourData.EnforcementPlane.Should().Be(PurviewEnforcementPlane.Application);
    }

    [Theory]
    [InlineData("AutomationApplication")]
    [InlineData("AutomationServicePrincipal")]
    [InlineData("KeyVaultResource")]
    [InlineData("KeyVaultHost")]
    [InlineData("CertificateName")]
    [InlineData("CertificateSecretUri")]
    [InlineData("ApiPrincipal")]
    [InlineData("WorkerPrincipal")]
    [InlineData("DeploymentOwnership")]
    [InlineData("SourceFingerprint")]
    public async Task HandleAsync_DlpMutationRejectsIncompleteOrDriftedCapabilityBinding(
        string drift)
    {
        var fixture = new HandlerFixture();
        fixture.Capability.ResourceIdentifiers = drift switch
        {
            "AutomationApplication" => fixture.Capability.ResourceIdentifiers with
            {
                PurviewAutomationApplicationId =
                    new ApplicationClientId(Guid.NewGuid())
            },
            "AutomationServicePrincipal" => fixture.Capability.ResourceIdentifiers with
            {
                PurviewAutomationServicePrincipalObjectId =
                    new ServicePrincipalObjectId(Guid.NewGuid())
            },
            "KeyVaultResource" => fixture.Capability.ResourceIdentifiers with
            {
                KeyVaultResourceId = KeyVaultResourceId.Replace(
                    "/vaults/gatewayvault",
                    "/vaults/othervault",
                    StringComparison.Ordinal)
            },
            "KeyVaultHost" => fixture.Capability.ResourceIdentifiers with
            {
                KeyVaultHost = "othervault.vault.azure.net"
            },
            "CertificateName" => fixture.Capability.ResourceIdentifiers with
            {
                CertificateName = "other-certificate"
            },
            "CertificateSecretUri" => fixture.Capability.ResourceIdentifiers with
            {
                CertificateSecretUri =
                    "https://gatewayvault.vault.azure.net/secrets/other-certificate"
            },
            "ApiPrincipal" => fixture.Capability.ResourceIdentifiers with
            {
                GatewayApiManagedIdentityPrincipalObjectId = null
            },
            "WorkerPrincipal" => fixture.Capability.ResourceIdentifiers with
            {
                PurviewRuntimeManagedIdentityPrincipalObjectId = null
            },
            "DeploymentOwnership" => fixture.Capability.ResourceIdentifiers with
            {
                BootstrapDeploymentOwnershipId = null
            },
            "SourceFingerprint" => fixture.Capability.ResourceIdentifiers with
            {
                BootstrapSourceFingerprint = null
            },
            _ => throw new InvalidOperationException("Unknown capability drift.")
        };
        var operation = fixture.CreateOperation(
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            fixture.Profile.Id.Value,
            currentStepIndex: 2);
        fixture.Arrange(operation);

        var result = await fixture.Handler.HandleAsync(
            nameof(ProtectionAdminOperationMessage),
            CreatePayload(operation, expectedStepIndex: 2),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(
            "PURVIEW_CAPABILITY_BINDING_INVALID");
        result.DeadLetterDescription.Should().Be(
            "Protection administration could not prove safe completion.");
        await fixture.SettingsProvider.DidNotReceiveWithAnyArgs()
            .EnsureDlpProfileAsync(default!, default);
    }

    private static string CreatePayload(
        ProtectionAdminOperation operation,
        int expectedStepIndex) =>
        JsonSerializer.Serialize(new ProtectionAdminOperationMessage(
            operation.Id,
            ProtectionAdminQueueContract.WorkflowVersion,
            expectedStepIndex,
            operation.CorrelationId));

    private sealed class HandlerFixture
    {
        public HandlerFixture()
        {
            Capability = new ProtectionCapability
            {
                Id = Guid.NewGuid(),
                Kind = ProtectionCapabilityKind.Purview,
                Status = ProtectionCapabilityStatus.Installed,
                ResourceIdentifiers = new ProtectionCapabilityResourceIdentifiers(
                    GatewayApiManagedIdentityPrincipalObjectId:
                        new ServicePrincipalObjectId(ApiPrincipalObjectId),
                    PurviewRuntimeManagedIdentityPrincipalObjectId:
                        new ServicePrincipalObjectId(WorkerPrincipalObjectId),
                    PurviewAutomationApplicationId:
                        new ApplicationClientId(AuthorityApplicationId),
                    PurviewAutomationServicePrincipalObjectId:
                        new ServicePrincipalObjectId(AuthorityServicePrincipalObjectId),
                    KeyVaultResourceId: KeyVaultResourceId,
                    CertificateName: CertificateName,
                    BootstrapDeploymentOwnershipId: DeploymentOwnershipId,
                    BootstrapSourceFingerprint: SourceFingerprint,
                    KeyVaultHost: KeyVaultHost,
                    CertificateSecretUri: CertificateSecretUri.AbsoluteUri),
                LastReadbackAtUtc = UtcNow.AddMinutes(-5),
                CreatedAtUtc = UtcNow.AddHours(-1),
                UpdatedAtUtc = UtcNow.AddMinutes(-5)
            };
            Connection = new PurviewTenantConnection
            {
                Id = Guid.NewGuid(),
                TenantId = TenantId,
                Status = PurviewTenantConnectionStatus.Connected,
                ActiveInventoryGenerationId = GenerationId,
                AuthorizedAtUtc = UtcNow.AddMinutes(-10),
                ExpiresAtUtc = UtcNow.AddMinutes(10),
                LastVerifiedAtUtc = UtcNow.AddMinutes(-5),
                CreatedByObjectId = ActorObjectId,
                AuthorityApplicationId =
                    new ApplicationClientId(AuthorityApplicationId),
                AuthorityServicePrincipalObjectId =
                    new ServicePrincipalObjectId(AuthorityServicePrincipalObjectId),
                AuthorityKind = "CertificateApplicationVerified",
                CreatedAtUtc = UtcNow.AddHours(-1),
                UpdatedAtUtc = UtcNow.AddMinutes(-5)
            };
            Generation = new PurviewSensitiveInformationTypeSnapshotGeneration
            {
                Id = GenerationId,
                PurviewTenantConnectionId = Connection.Id,
                TenantId = TenantId,
                RetrievedAtUtc = UtcNow.AddMinutes(-5),
                ExpiresAtUtc = UtcNow.AddMinutes(10),
                ItemCount = 1,
                CreatedAtUtc = UtcNow.AddMinutes(-5)
            };
            Generation.Items.Add(new PurviewSensitiveInformationTypeSnapshot
            {
                Id = Guid.NewGuid(),
                GenerationId = GenerationId,
                SensitiveInformationTypeId = SensitiveInformationTypeId,
                ExactName = SensitiveInformationTypeName,
                Publisher = Publisher,
                SortOrder = 0
            });
            Generations.Add(Generation.Id.Value, Generation);
            KnowYourData = new PurviewKnowYourDataConfiguration
            {
                Id = Guid.NewGuid(),
                PurviewTenantConnectionId = Connection.Id,
                InventoryGenerationId = GenerationId,
                SensitiveInformationTypeId = SensitiveInformationTypeId,
                SensitiveInformationTypeName = SensitiveInformationTypeName,
                Mode = PurviewMode.AuditOnly,
                Activities =
                [
                    PurviewPolicyActivity.UploadText,
                    PurviewPolicyActivity.DownloadText
                ],
                IngestionEnabled = true,
                Status = PurviewKnowYourDataStatus.Pending,
                ReadbackStatus = ProtectionReadbackStatus.Pending,
                CreatedAtUtc = UtcNow.AddMinutes(-4),
                UpdatedAtUtc = UtcNow.AddMinutes(-4)
            };
            Profile = new PurviewDlpProfile
            {
                Id = new PurviewDlpProfileId(Guid.NewGuid()),
                PurviewTenantConnectionId = Connection.Id,
                BlueprintApplicationId = new BlueprintApplicationId(Guid.NewGuid()),
                DisplayName = "Synthetic protected blueprint",
                InventoryGenerationId = GenerationId,
                SensitiveInformationTypeSnapshotExpiresAtUtc = Generation.ExpiresAtUtc,
                SensitiveInformationTypeId = SensitiveInformationTypeId,
                SensitiveInformationTypeName = SensitiveInformationTypeName,
                Mode = PurviewMode.Enforce,
                Activities = [PurviewPolicyActivity.UploadText],
                Actions =
                [
                    new PurviewDlpRuleAction(
                        PurviewPolicyActivity.UploadText,
                        PurviewDlpAction.Block)
                ],
                Status = PurviewDlpProfileStatus.Pending,
                Readiness = new ProtectionReadiness(
                    ProtectionCapabilityStatus.Installed,
                    ProtectionReadbackStatus.Pending,
                    ProtectionPropagationStatus.NotChecked,
                    ProtectionTokenRoleStatus.NotChecked,
                    ProtectionRuntimeVerdictStatus.NotChecked),
                CreatedAtUtc = UtcNow.AddMinutes(-4),
                UpdatedAtUtc = UtcNow.AddMinutes(-4)
            };

            Locks.AcquireExecutionAsync(Arg.Any<Guid>(), Arg.Any<CancellationToken>())
                .Returns(Substitute.For<IAsyncDisposable>());
            UnitOfWork.SaveChangesAsync(Arg.Any<CancellationToken>())
                .Returns(Task.FromResult(1));
            Outbox.AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>())
                .Returns(call =>
                {
                    AddedOutboxMessages.Add(call.Arg<OutboxMessage>());
                    return Task.CompletedTask;
                });
            Inventories.GetGenerationAsync(
                    Arg.Any<SensitiveInformationTypeSnapshotGenerationId>(),
                    Arg.Any<CancellationToken>())
                .Returns(call =>
                {
                    Generations.TryGetValue(
                        call.Arg<SensitiveInformationTypeSnapshotGenerationId>().Value,
                        out var generation);
                    return generation;
                });
            Inventories.AddGenerationAsync(
                    Arg.Any<PurviewSensitiveInformationTypeSnapshotGeneration>(),
                    Arg.Any<CancellationToken>())
                .Returns(call =>
                {
                    var generation =
                        call.Arg<PurviewSensitiveInformationTypeSnapshotGeneration>();
                    Generations.Add(generation.Id.Value, generation);
                    AddedGenerations.Add(generation);
                    return Task.CompletedTask;
                });

            Handler = new ProtectionAdminMessageHandler(
                Operations,
                Capabilities,
                Connections,
                Inventories,
                KnowYourDataConfigurations,
                DlpProfiles,
                ConnectionVerifier,
                SettingsProvider,
                TokenRoleAttestor,
                RuntimeValidator,
                Outbox,
                UnitOfWork,
                Locks,
                Options.Create(new ProtectionAdminWorkerOptions
                {
                    MaximumPropagationAttempts = 3,
                    PropagationRetryDelaySeconds = 1
                }),
                Options.Create(new PurviewOptions
                {
                    Enabled = true,
                    PolicyProvisioningEnabled = true,
                    PolicyProvisioningApplicationId =
                        AuthorityApplicationId.ToString("D"),
                    PolicyProvisioningCertificateSecretUri =
                        CertificateSecretUri.AbsoluteUri
                }),
                new ConfigurationBuilder()
                    .AddInMemoryCollection(new Dictionary<string, string?>
                    {
                        ["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] =
                            WorkerPrincipalObjectId.ToString("D")
                    })
                    .Build(),
                NullLogger<ProtectionAdminMessageHandler>.Instance,
                new FixedTimeProvider(UtcNow));
        }

        public EntraTenantId TenantId { get; } = new(Guid.NewGuid());
        public SensitiveInformationTypeSnapshotGenerationId GenerationId { get; } =
            new(Guid.NewGuid());
        public SensitiveInformationTypeId SensitiveInformationTypeId { get; } =
            new(Guid.NewGuid());
        public ProtectionCapability Capability { get; }
        public PurviewTenantConnection Connection { get; }
        public PurviewSensitiveInformationTypeSnapshotGeneration Generation { get; }
        public PurviewKnowYourDataConfiguration KnowYourData { get; }
        public PurviewDlpProfile Profile { get; }
        public IProtectionAdminOperationRepository Operations { get; } =
            Substitute.For<IProtectionAdminOperationRepository>();
        public IProtectionCapabilityRepository Capabilities { get; } =
            Substitute.For<IProtectionCapabilityRepository>();
        public IPurviewTenantConnectionRepository Connections { get; } =
            Substitute.For<IPurviewTenantConnectionRepository>();
        public IPurviewSensitiveInformationTypeSnapshotRepository Inventories { get; } =
            Substitute.For<IPurviewSensitiveInformationTypeSnapshotRepository>();
        public IPurviewKnowYourDataConfigurationRepository KnowYourDataConfigurations { get; } =
            Substitute.For<IPurviewKnowYourDataConfigurationRepository>();
        public IPurviewDlpProfileRepository DlpProfiles { get; } =
            Substitute.For<IPurviewDlpProfileRepository>();
        public IPurviewConnectionVerificationProvider ConnectionVerifier { get; } =
            Substitute.For<IPurviewConnectionVerificationProvider>();
        public IPurviewSettingsProvider SettingsProvider { get; } =
            Substitute.For<IPurviewSettingsProvider>();
        public IPurviewTokenRoleAttestor TokenRoleAttestor { get; } =
            Substitute.For<IPurviewTokenRoleAttestor>();
        public IPurviewRuntimeReadinessValidator RuntimeValidator { get; } =
            Substitute.For<IPurviewRuntimeReadinessValidator>();
        public IOutboxRepository Outbox { get; } = Substitute.For<IOutboxRepository>();
        public IUnitOfWork UnitOfWork { get; } = Substitute.For<IUnitOfWork>();
        public IProtectionAdminOperationLockProvider Locks { get; } =
            Substitute.For<IProtectionAdminOperationLockProvider>();
        public List<OutboxMessage> AddedOutboxMessages { get; } = [];
        public List<PurviewSensitiveInformationTypeSnapshotGeneration> AddedGenerations { get; } =
            [];
        public ProtectionAdminMessageHandler Handler { get; }
        private Dictionary<Guid, PurviewSensitiveInformationTypeSnapshotGeneration> Generations
        {
            get;
        } = [];

        public ProtectionAdminOperation CreateOperation(
            ProtectionAdminOperationType type,
            ProtectionAdminTargetType targetType,
            Guid targetId,
            int currentStepIndex)
        {
            if (type == ProtectionAdminOperationType.ConnectPurviewTenant &&
                Connection.Status == PurviewTenantConnectionStatus.PendingVerification)
            {
                Connection.AuthorityKind = "InteractiveSubmissionUnverified";
            }

            var operation = new ProtectionAdminOperation
            {
                Id = Guid.NewGuid(),
                WorkflowVersion = ProtectionAdminWorkflow.CurrentVersion,
                Type = type,
                Status = ProtectionAdminOperationStatus.Pending,
                TenantId = TenantId,
                ActorObjectId = ActorObjectId,
                TargetType = targetType,
                TargetIdentifier = targetId.ToString("D"),
                ReviewedPayloadHash = type switch
                {
                    ProtectionAdminOperationType.ConnectPurviewTenant or
                    ProtectionAdminOperationType.RefreshSensitiveInformationTypes =>
                        ProtectionAdminIntentFingerprint.ForConnection(
                            TenantId.Value),
                    ProtectionAdminOperationType.CreateOrUpdateKnowYourData =>
                        ProtectionAdminIntentFingerprint.ForKnowYourData(
                            KnowYourData),
                    _ => ProtectionAdminIntentFingerprint.ForDlpProfile(Profile)
                },
                AcceptedRequestHash =
                    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                IdempotencyKey = new ProtectionIdempotencyKey(
                    Guid.Parse("00000000-0000-4000-8000-000000000001")),
                MaximumAttempts = 3,
                CorrelationId = Guid.NewGuid(),
                CreatedAtUtc = UtcNow.AddMinutes(-1),
                UpdatedAtUtc = UtcNow.AddMinutes(-1)
            };
            operation.ConfirmationVerifier = new ProtectionConfirmationVerifier(
                Guid.NewGuid(),
                Guid.NewGuid(),
                1,
                "PBKDF2-SHA256",
                [1],
                [2],
                UtcNow.AddMinutes(5));
            operation.ConfirmationVerifier.MarkConsumed(UtcNow.AddMinutes(-1));
            for (var index = 0; index < ProtectionAdminWorkflow.CurrentSteps.Count; index++)
            {
                operation.AddStep(new ProtectionAdminOperationStep
                {
                    Id = Guid.NewGuid(),
                    StepType = ProtectionAdminWorkflow.CurrentSteps[index],
                    Status = index < currentStepIndex
                        ? ProtectionAdminStepStatus.Completed
                        : ProtectionAdminStepStatus.Pending,
                    OrderIndex = index,
                    RetryDisposition = ProtectionRetryDisposition.NotApplicable,
                    CompletedAtUtc = index < currentStepIndex
                        ? UtcNow.AddMinutes(-1)
                        : null
                });
            }

            return operation;
        }

        public void Arrange(ProtectionAdminOperation operation)
        {
            Operations.GetByIdAsync(operation.Id, Arg.Any<CancellationToken>())
                .Returns(operation);
            Capabilities.GetByKindAsync(
                    ProtectionCapabilityKind.Purview,
                    Arg.Any<CancellationToken>())
                .Returns(Capability);
            Connections.GetByIdAsync(Connection.Id, Arg.Any<CancellationToken>())
                .Returns(Connection);
            Connections.GetByTenantIdAsync(TenantId, Arg.Any<CancellationToken>())
                .Returns(Connection);
            KnowYourDataConfigurations.GetByTenantIdAsync(
                    TenantId,
                    Arg.Any<CancellationToken>())
                .Returns(KnowYourData);
            DlpProfiles.GetByIdAsync(Profile.Id, Arg.Any<CancellationToken>())
                .Returns(Profile);
        }

        public PurviewConnectionVerificationEvidence CreateConnectionProviderEvidence(
            ProtectionAdminOperation operation) =>
            PurviewConnectionVerificationEvidence.Create(
                operation.Id,
                TenantId.Value,
                Guid.Parse(ActorObjectId),
                AuthorityApplicationId,
                AuthorityServicePrincipalObjectId,
                KeyVaultResourceId,
                KeyVaultHost,
                CertificateName,
                CertificateSecretUri,
                ProviderCertificateSecretId,
                new DateTimeOffset(UtcNow, TimeSpan.Zero),
                new DateTimeOffset(UtcNow.AddMinutes(10), TimeSpan.Zero),
                [
                    new PurviewConnectionInventoryItem(
                        SensitiveInformationTypeId.Value,
                        SensitiveInformationTypeName,
                        Publisher,
                        SortOrder: 0)
                ]);

        public PurviewDlpProfileReadback CreateDlpReadback() => new(
            "policy-exact",
            "rule-exact",
            TenantId.Value,
            [Profile.BlueprintApplicationId.Value],
            PurviewPolicyScopeType.Individual,
            PurviewEnforcementPlane.Application,
            SensitiveInformationTypeId.Value,
            SensitiveInformationTypeName,
            Publisher,
            Profile.Mode,
            Profile.Activities.ToArray(),
            Profile.Actions.ToArray(),
            HasExclusions: false,
            HasBypass: false,
            new DateTimeOffset(UtcNow, TimeSpan.Zero));

        public PurviewKnowYourDataReadback CreateKnowYourDataReadback(
            PurviewKnowYourDataIntent intent) => new(
            "kyd-policy-exact",
            TenantId.Value,
            PurviewPolicyLocationContract.EnterpriseAiAppsGroupId,
            PurviewPolicyScopeType.Group,
            PurviewEnforcementPlane.Application,
            SensitiveInformationTypeId.Value,
            SensitiveInformationTypeName,
            Publisher,
            intent.Mode,
            intent.Activities,
            intent.IngestionEnabled,
            new DateTimeOffset(UtcNow, TimeSpan.Zero));
    }

    private sealed class FixedTimeProvider(DateTime utcNow) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() =>
            new(DateTime.SpecifyKind(utcNow, DateTimeKind.Utc), TimeSpan.Zero);
    }

    private const string ActorObjectId = "00000000-0000-4000-8000-000000000002";
    private const string SensitiveInformationTypeName = "Synthetic financial identifier";
    private const string Publisher = "Contoso";
    private static readonly Guid AuthorityApplicationId =
        Guid.Parse("00000000-0000-4000-8000-000000000003");
    private static readonly Guid AuthorityServicePrincipalObjectId =
        Guid.Parse("00000000-0000-4000-8000-000000000004");
    private static readonly Guid ApiPrincipalObjectId =
        Guid.Parse("00000000-0000-4000-8000-000000000006");
    private static readonly Guid WorkerPrincipalObjectId =
        Guid.Parse("00000000-0000-4000-8000-000000000007");
    private static readonly Guid DeploymentOwnershipId =
        Guid.Parse("00000000-0000-4000-8000-000000000008");
    private const string SourceFingerprint =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string KeyVaultResourceId =
        "/subscriptions/00000000-0000-4000-8000-000000000005/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gatewayvault";
    private const string KeyVaultHost = "gatewayvault.vault.azure.net";
    private const string CertificateName = "purview-automation";
    private static readonly Uri CertificateSecretUri =
        new("https://gatewayvault.vault.azure.net/secrets/purview-automation");
    private static readonly Uri ProviderCertificateSecretId =
        new("https://gatewayvault.vault.azure.net/secrets/purview-automation/version");
    private static readonly DateTime UtcNow =
        new(2026, 9, 5, 10, 0, 0, DateTimeKind.Utc);
}
