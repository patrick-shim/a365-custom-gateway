using FluentAssertions;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Purview;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Gateway.UnitTests.Purview;

public sealed class PurviewTenantConnectionEvidenceValidatorTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 9, 5, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Validate_ExactBoundedEvidence_ProducesCanonicalSortedInventory()
    {
        var binding = CreateBinding();
        var evidence = CreateEvidence(binding) with
        {
            SensitiveInformationTypes =
            [
                new(
                    "22222222-2222-4222-8222-222222222222",
                    "신용 카드 번호",
                    "Microsoft"),
                new(
                    "11111111-1111-4111-8111-111111111111",
                    "Bank Account Number",
                    "Microsoft")
            ]
        };

        var result = new PurviewTenantConnectionEvidenceValidator()
            .Validate(binding, evidence, Now);

        result.OperationId.Should().Be(binding.OperationId);
        result.TenantId.Should().Be(binding.TenantId);
        result.AdministratorObjectId.Should().Be(binding.AdministratorObjectId);
        result.Inventory.GenerationId.Should().Be(binding.InventoryGenerationId);
        result.Inventory.Items.Select(item => item.ExactName)
            .Should().ContainInOrder("Bank Account Number", "신용 카드 번호");
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void Validate_WrongTenantOrAdministrator_IsRejected(
        bool wrongTenant,
        bool wrongAdministrator)
    {
        var binding = CreateBinding();
        var evidence = CreateEvidence(binding) with
        {
            TenantId = (wrongTenant ? Guid.NewGuid() : binding.TenantId).ToString("D"),
            AdministratorObjectId = (wrongAdministrator
                ? Guid.NewGuid()
                : binding.AdministratorObjectId).ToString("D")
        };

        var action = () => new PurviewTenantConnectionEvidenceValidator()
            .Validate(binding, evidence, Now);

        action.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_CONNECTION_BINDING_MISMATCH");
    }

    [Fact]
    public void Validate_NoncanonicalIdOrStaleGeneration_IsRejected()
    {
        var binding = CreateBinding();
        var noncanonical = CreateEvidence(binding) with
        {
            TenantId = binding.TenantId.ToString("B")
        };
        var stale = CreateEvidence(binding) with
        {
            InventoryGenerationId = Guid.NewGuid().ToString("D")
        };
        var validator = new PurviewTenantConnectionEvidenceValidator();

        var noncanonicalAction = () => validator.Validate(binding, noncanonical, Now);
        var staleAction = () => validator.Validate(binding, stale, Now);

        noncanonicalAction.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_CONNECTION_EVIDENCE_INVALID");
        staleAction.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_CONNECTION_BINDING_MISMATCH");
    }

    [Fact]
    public void Validate_ExpiredEvidenceOrDuplicateInventory_IsRejected()
    {
        var binding = CreateBinding();
        var expiredBinding = binding with { ExpiresAtUtc = Now.AddSeconds(-1) };
        var expired = CreateEvidence(expiredBinding) with
        {
            ObservedAtUtc = Now.AddMinutes(-10)
        };
        var duplicateId = CreateEvidence(binding);
        duplicateId = duplicateId with
        {
            SensitiveInformationTypes =
            [
                duplicateId.SensitiveInformationTypes[0],
                duplicateId.SensitiveInformationTypes[0] with { ExactName = "Other" }
            ]
        };
        var validator = new PurviewTenantConnectionEvidenceValidator();

        var expiredAction = () => validator.Validate(expiredBinding, expired, Now);
        var duplicateAction = () => validator.Validate(binding, duplicateId, Now);

        expiredAction.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_CONNECTION_EVIDENCE_EXPIRED");
        duplicateAction.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_SIT_INVENTORY_INVALID");
    }

    private static PurviewTenantConnectionOperationBinding CreateBinding() => new(
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        Guid.Parse("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
        Guid.Parse("dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
        Now.AddMinutes(10));

    private static PurviewTenantConnectionCompanionEvidence CreateEvidence(
        PurviewTenantConnectionOperationBinding binding) => new(
        binding.OperationId.ToString("D"),
        binding.TenantId.ToString("D"),
        binding.AdministratorObjectId.ToString("D"),
        binding.InventoryGenerationId.ToString("D"),
        Now,
        binding.ExpiresAtUtc,
        PurviewTenantConnectionEvidenceValidator.RequiredCapabilities,
        [
            new(
                "11111111-1111-4111-8111-111111111111",
                "Credit Card Number",
                "Microsoft")
        ]);
}

public sealed class PurviewCompanionEvidenceParserTests
{
    [Fact]
    public void Parse_OneTypedBoundedClaim_IsAccepted()
    {
        var evidence = new PurviewTenantConnectionCompanionEvidence(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow.AddMinutes(10),
            PurviewTenantConnectionEvidenceValidator.RequiredCapabilities,
            [
                new(
                    "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                    "Credit Card Number",
                    "Microsoft")
            ]);
        var json = JsonSerializer.Serialize(evidence, new JsonSerializerOptions(
            JsonSerializerDefaults.Web));
        var output = PurviewCompanionEvidenceParser.ResultPrefix +
            Convert.ToBase64String(Encoding.UTF8.GetBytes(json));

        var parsed = PurviewCompanionEvidenceParser.Parse(output);

        parsed.Should().BeEquivalentTo(evidence);
    }

    [Fact]
    public void Parse_DuplicateOrUnrecognizedClaim_IsRejected()
    {
        var unknownPayload = Convert.ToBase64String(Encoding.UTF8.GetBytes(
            """{"operationId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","unexpected":"value"}"""));
        var duplicate =
            $"{PurviewCompanionEvidenceParser.ResultPrefix}{unknownPayload}\n" +
            $"{PurviewCompanionEvidenceParser.ResultPrefix}{unknownPayload}";

        var unknownAction = () => PurviewCompanionEvidenceParser.Parse(
            PurviewCompanionEvidenceParser.ResultPrefix + unknownPayload);
        var duplicateAction = () => PurviewCompanionEvidenceParser.Parse(duplicate);

        unknownAction.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_CONNECTION_EVIDENCE_INVALID");
        duplicateAction.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be("PURVIEW_CONNECTION_EVIDENCE_INVALID");
    }

    [Fact]
    public void Command_ContainsOnlyCanonicalOperationBindingArguments()
    {
        var binding = new PurviewTenantConnectionOperationBinding(
            Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            Guid.Parse("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
            Guid.Parse("dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
            new DateTimeOffset(2026, 9, 5, 10, 10, 0, TimeSpan.Zero));

        var arguments = PurviewCompanionCommand.CreateArguments(binding);

        arguments.Should().ContainInOrder(
            "-NoLogo",
            "-NoProfile",
            "-File",
            PurviewCompanionCommand.ScriptFileName,
            "-OperationId",
            binding.OperationId.ToString("D"),
            "-TenantId",
            binding.TenantId.ToString("D"),
            "-AdministratorObjectId",
            binding.AdministratorObjectId.ToString("D"),
            "-InventoryGenerationId",
            binding.InventoryGenerationId.ToString("D"),
            "-ExpiresAtUtc",
            binding.ExpiresAtUtc.ToString("O"));
        arguments.Should().NotContain(value =>
            value.Contains("token", StringComparison.OrdinalIgnoreCase) ||
            value.Contains("credential", StringComparison.OrdinalIgnoreCase));
    }
}

public sealed class PurviewSettingsProviderTests
{
    [Fact]
    public async Task EnsureKnowYourData_ExactReadback_DoesNotMutate()
    {
        var intent = CreateKnowYourDataIntent();
        var readback = PurviewProviderReadback.Exact(CreateKnowYourDataReadback(intent));
        var automation = new RecordingAutomation
        {
            KnowYourDataReads = new Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>(
                [readback])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureKnowYourDataAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(PurviewSettingsOperationDisposition.AlreadyExact);
        automation.Mutations.Should().BeEmpty();
        result.Readback!.GroupId.Should().Be(PurviewPolicyLocationContract.EnterpriseAiAppsGroupId);
        result.Readback.ScopeType.Should().Be(PurviewPolicyScopeType.Group);
        result.Readback.EnforcementPlane.Should().Be(PurviewEnforcementPlane.Application);
    }

    [Fact]
    public async Task EnsureKnowYourData_UnknownCreateOutcome_UsesReadbackAndNeverRepeatsCreate()
    {
        var intent = CreateKnowYourDataIntent();
        var automation = new RecordingAutomation
        {
            KnowYourDataReads = new Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>(
            [
                PurviewProviderReadback<PurviewKnowYourDataReadback>.Absent(),
                PurviewProviderReadback.Exact(CreateKnowYourDataReadback(intent))
            ]),
            KnowYourDataMutationException = new PurviewMutationOutcomeUnknownException(
                "PURVIEW_KYD_MUTATION_UNKNOWN")
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureKnowYourDataAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome);
        automation.Mutations.Should().ContainSingle()
            .Which.Should().Be(PurviewSettingsAutomationMutation.CreateKnowYourData);
        automation.Calls.Should().ContainInOrder("ReadKyd", "CreateKyd", "ReadKyd");
    }

    [Fact]
    public async Task EnsureKnowYourData_RedeliveryAfterUnknownOutcome_NeverRepeatsCreate()
    {
        var intent = CreateKnowYourDataIntent() with
        {
            PriorCreateOutcomeUnknown = true
        };
        var automation = new RecordingAutomation
        {
            KnowYourDataReads = new Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>(
                [PurviewProviderReadback<PurviewKnowYourDataReadback>.Absent()])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureKnowYourDataAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RequiresManualIntervention);
        result.FailureCode.Should().Be("PURVIEW_KYD_PRIOR_MUTATION_UNRESOLVED");
        automation.Mutations.Should().BeEmpty();
    }

    [Fact]
    public async Task EnsureKnowYourData_OwnedMismatch_UpdatesThenReadsExactState()
    {
        var intent = CreateKnowYourDataIntent() with
        {
            ExpectedPolicyProviderId = "kyd-provider-id"
        };
        var automation = new RecordingAutomation
        {
            KnowYourDataReads = new Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>(
            [
                PurviewProviderReadback<PurviewKnowYourDataReadback>.Mismatch(),
                PurviewProviderReadback.Exact(CreateKnowYourDataReadback(intent))
            ])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureKnowYourDataAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(PurviewSettingsOperationDisposition.MutatedAndVerified);
        automation.Mutations.Should().ContainSingle()
            .Which.Should().Be(PurviewSettingsAutomationMutation.CreateKnowYourData);
        automation.Calls.Should().ContainInOrder("ReadKyd", "CreateKyd", "ReadKyd");
    }

    [Fact]
    public async Task EnsureKnowYourData_UnownedMismatch_DoesNotMutate()
    {
        var intent = CreateKnowYourDataIntent();
        var automation = new RecordingAutomation
        {
            KnowYourDataReads = new Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>(
                [PurviewProviderReadback<PurviewKnowYourDataReadback>.Mismatch()])
        };
        var provider = new PurviewSettingsProvider(automation);

        var action = () => provider.EnsureKnowYourDataAsync(
            intent,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_KYD_STATE_UNVERIFIABLE");
        automation.Mutations.Should().BeEmpty();
    }

    [Fact]
    public async Task EnsureKnowYourData_UnknownOwnedUpdate_UsesReadbackAndNeverRepeatsMutation()
    {
        var intent = CreateKnowYourDataIntent() with
        {
            ExpectedPolicyProviderId = "kyd-provider-id"
        };
        var automation = new RecordingAutomation
        {
            KnowYourDataReads = new Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>(
            [
                PurviewProviderReadback<PurviewKnowYourDataReadback>.Mismatch(),
                PurviewProviderReadback.Exact(CreateKnowYourDataReadback(intent))
            ]),
            KnowYourDataMutationException = new PurviewMutationOutcomeUnknownException(
                "PURVIEW_KYD_UPDATE_UNKNOWN")
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureKnowYourDataAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome);
        automation.Mutations.Should().ContainSingle()
            .Which.Should().Be(PurviewSettingsAutomationMutation.CreateKnowYourData);
        automation.Calls.Should().ContainInOrder("ReadKyd", "CreateKyd", "ReadKyd");
    }

    [Theory]
    [InlineData(PurviewMode.Enforce)]
    [InlineData(PurviewMode.AuditOnly)]
    public async Task EnsureDlpProfile_CreatesPolicyThenReadsBeforeCreatingRule(PurviewMode mode)
    {
        var intent = CreateDlpIntent() with
        {
            Mode = mode,
            Activities = [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText],
            Actions = Gateway.Application.Protection.ProtectionAdministrationRules.ParseActions(
                [new("UploadText", "Block")],
                [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText])
        };
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
            [
                PurviewProviderReadback<PurviewDlpProfileReadback>.Absent(),
                PurviewProviderReadback.PolicyOnly(CreateDlpReadback(intent, includeRule: false)),
                PurviewProviderReadback.Exact(CreateDlpReadback(intent))
            ])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(PurviewSettingsOperationDisposition.MutatedAndVerified);
        automation.Calls.Should().ContainInOrder(
            "ReadDlp",
            "CreateDlpPolicy",
            "ReadDlp",
            "CreateDlpRule",
            "ReadDlp");
        result.Readback!.BlueprintApplicationIds.Should()
            .ContainSingle(value => value == intent.BlueprintApplicationId);
        result.Readback.ScopeType.Should().Be(PurviewPolicyScopeType.Individual);
        result.Readback.EnforcementPlane.Should().Be(PurviewEnforcementPlane.Application);
        result.Readback.Mode.Should().Be(mode);
        result.Readback.Actions.Should().ContainSingle().Which.Should().Be(
            new PurviewDlpRuleAction(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block));
    }

    [Fact]
    public async Task EnsureDlpProfile_UnknownRuleOutcomeWithoutExactRecovery_RequiresManualIntervention()
    {
        var intent = CreateDlpIntent();
        var policyOnly = CreateDlpReadback(intent, includeRule: false);
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
            [
                PurviewProviderReadback.PolicyOnly(policyOnly),
                PurviewProviderReadback.PolicyOnly(policyOnly)
            ]),
            DlpRuleMutationException = new PurviewMutationOutcomeUnknownException(
                "PURVIEW_DLP_RULE_MUTATION_UNKNOWN")
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RequiresManualIntervention);
        result.Readback!.PolicyProviderId.Should().Be("dlp-provider-id");
        result.Readback.RuleProviderId.Should().BeNull();
        automation.Mutations.Should().ContainSingle()
            .Which.Should().Be(PurviewSettingsAutomationMutation.CreateDlpRule);
        automation.Calls.Should().ContainInOrder(
            "ReadDlp",
            "CreateDlpRule",
            "ReadDlp");
    }

    [Fact]
    public async Task EnsureDlpProfile_OwnedMismatch_UpdatesPolicyThenRuleWithSeparateReadbacks()
    {
        var intent = CreateDlpIntent() with
        {
            ExpectedPolicyProviderId = "dlp-provider-id",
            ExpectedRuleProviderId = "rule-provider-id"
        };
        var policyExactRuleMismatched = CreateDlpReadback(intent, includeRule: false) with
        {
            RuleProviderId = "rule-provider-id"
        };
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
            [
                PurviewProviderReadback<PurviewDlpProfileReadback>.Mismatch(),
                PurviewProviderReadback.PolicyOnly(policyExactRuleMismatched),
                PurviewProviderReadback.Exact(CreateDlpReadback(intent))
            ])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(PurviewSettingsOperationDisposition.MutatedAndVerified);
        automation.Mutations.Should().ContainInOrder(
            PurviewSettingsAutomationMutation.CreateDlpPolicy,
            PurviewSettingsAutomationMutation.CreateDlpRule);
        automation.Calls.Should().ContainInOrder(
            "ReadDlp",
            "CreateDlpPolicy",
            "ReadDlp",
            "CreateDlpRule",
            "ReadDlp");
    }

    [Fact]
    public async Task EnsureDlpProfile_UnknownOwnedRuleUpdate_UsesReadbackAndNeverRepeatsMutation()
    {
        var intent = CreateDlpIntent() with
        {
            ExpectedPolicyProviderId = "dlp-provider-id",
            ExpectedRuleProviderId = "rule-provider-id"
        };
        var policyExactRuleMismatched = CreateDlpReadback(intent, includeRule: false) with
        {
            RuleProviderId = "rule-provider-id"
        };
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
            [
                PurviewProviderReadback.PolicyOnly(policyExactRuleMismatched),
                PurviewProviderReadback.Exact(CreateDlpReadback(intent))
            ]),
            DlpRuleMutationException = new PurviewMutationOutcomeUnknownException(
                "PURVIEW_DLP_RULE_MUTATION_UNKNOWN")
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome);
        automation.Mutations.Should().ContainSingle()
            .Which.Should().Be(PurviewSettingsAutomationMutation.CreateDlpRule);
        automation.Calls.Should().ContainInOrder(
            "ReadDlp",
            "CreateDlpRule",
            "ReadDlp");
    }

    [Fact]
    public async Task EnsureDlpProfile_UnknownOwnedPolicyUpdate_UsesReadbackAndNeverMutatesRule()
    {
        var intent = CreateDlpIntent() with
        {
            ExpectedPolicyProviderId = "dlp-provider-id",
            ExpectedRuleProviderId = "rule-provider-id"
        };
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
            [
                PurviewProviderReadback<PurviewDlpProfileReadback>.Mismatch(),
                PurviewProviderReadback.Exact(CreateDlpReadback(intent))
            ]),
            DlpPolicyMutationException = new PurviewMutationOutcomeUnknownException(
                "PURVIEW_DLP_POLICY_UPDATE_UNKNOWN")
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome);
        automation.Mutations.Should().ContainSingle()
            .Which.Should().Be(PurviewSettingsAutomationMutation.CreateDlpPolicy);
        automation.Calls.Should().ContainInOrder(
            "ReadDlp",
            "CreateDlpPolicy",
            "ReadDlp");
    }

    [Fact]
    public async Task EnsureDlpProfile_UnownedMismatch_DoesNotMutate()
    {
        var intent = CreateDlpIntent();
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
                [PurviewProviderReadback<PurviewDlpProfileReadback>.Mismatch()])
        };
        var provider = new PurviewSettingsProvider(automation);

        var action = () => provider.EnsureDlpProfileAsync(
            intent,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_DLP_STATE_UNVERIFIABLE");
        automation.Mutations.Should().BeEmpty();
    }

    [Fact]
    public async Task EnsureDlpProfile_RedeliveryAfterUnknownRule_NeverRepeatsRuleCreate()
    {
        var intent = CreateDlpIntent() with
        {
            RecoveryPoint = PurviewDlpMutationRecoveryPoint.RuleCreationOutcomeUnknown
        };
        var policyOnly = CreateDlpReadback(intent, includeRule: false);
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
                [PurviewProviderReadback.PolicyOnly(policyOnly)])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(
            PurviewSettingsOperationDisposition.RequiresManualIntervention);
        result.Readback!.PolicyProviderId.Should().Be("dlp-provider-id");
        result.FailureCode.Should().Be(
            "PURVIEW_DLP_RULE_PRIOR_MUTATION_UNRESOLVED");
        automation.Mutations.Should().BeEmpty();
    }

    [Fact]
    public async Task EnsureDlpProfile_WiderLocationScope_FailsClosedWithoutMutation()
    {
        var intent = CreateDlpIntent();
        var readback = CreateDlpReadback(intent) with
        {
            BlueprintApplicationIds =
            [
                intent.BlueprintApplicationId,
                Guid.Parse("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
            ]
        };
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
                [PurviewProviderReadback.Exact(readback)])
        };
        var provider = new PurviewSettingsProvider(automation);

        var action = () => provider.EnsureDlpProfileAsync(intent, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_DLP_READBACK_MISMATCH");
        automation.Mutations.Should().BeEmpty();
    }

    [Fact]
    public async Task ReconcileDlpProfile_IsReadOnly()
    {
        var intent = CreateDlpIntent();
        var automation = new RecordingAutomation
        {
            DlpReads = new Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>(
                [PurviewProviderReadback.Exact(CreateDlpReadback(intent))])
        };
        var provider = new PurviewSettingsProvider(automation);

        var result = await provider.ReconcileDlpProfileAsync(intent, CancellationToken.None);

        result.Disposition.Should().Be(PurviewSettingsOperationDisposition.ExactReadback);
        automation.Mutations.Should().BeEmpty();
    }

    [Fact]
    public async Task EnsureDlpProfile_UnsupportedResponseBlockingIntent_FailsBeforeProviderCall()
    {
        var intent = CreateDlpIntent() with
        {
            Activities =
            [
                PurviewPolicyActivity.UploadText,
                PurviewPolicyActivity.DownloadText
            ],
            Actions =
            [
                new(
                    PurviewPolicyActivity.DownloadText,
                    PurviewDlpAction.Block)
            ]
        };
        var automation = new RecordingAutomation();
        var provider = new PurviewSettingsProvider(automation);

        var action = () => provider.EnsureDlpProfileAsync(
            intent,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_DLP_INTENT_INVALID");
        automation.Calls.Should().BeEmpty();
    }

    private static PurviewKnowYourDataIntent CreateKnowYourDataIntent() => new(
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        Guid.Parse("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
        DateTimeOffset.UtcNow.AddMinutes(10),
        Guid.Parse("dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
        "Credit Card Number",
        "Microsoft",
        "Gateway KYD",
        PurviewMode.Enforce,
        [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText],
        true,
        null);

    private static PurviewDlpProfileIntent CreateDlpIntent() => new(
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        Guid.Parse("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
        DateTimeOffset.UtcNow.AddMinutes(10),
        Guid.Parse("dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
        "Credit Card Number",
        "Microsoft",
        Guid.Parse("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"),
        "Gateway DLP",
        "Gateway DLP rule",
        PurviewMode.Enforce,
        [PurviewPolicyActivity.UploadText],
        [new PurviewDlpRuleAction(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)],
        null,
        null);

    private static PurviewKnowYourDataReadback CreateKnowYourDataReadback(
        PurviewKnowYourDataIntent intent) => new(
        "kyd-provider-id",
        intent.TenantId,
        PurviewPolicyLocationContract.EnterpriseAiAppsGroupId,
        PurviewPolicyScopeType.Group,
        PurviewEnforcementPlane.Application,
        intent.SensitiveInformationTypeId,
        intent.SensitiveInformationTypeName,
        intent.SensitiveInformationTypePublisher,
        intent.Mode,
        intent.Activities,
        intent.IngestionEnabled,
        DateTimeOffset.UtcNow);

    private static PurviewDlpProfileReadback CreateDlpReadback(
        PurviewDlpProfileIntent intent,
        bool includeRule = true) => new(
        "dlp-provider-id",
        includeRule ? "rule-provider-id" : null,
        intent.TenantId,
        [intent.BlueprintApplicationId],
        PurviewPolicyScopeType.Individual,
        PurviewEnforcementPlane.Application,
        intent.SensitiveInformationTypeId,
        intent.SensitiveInformationTypeName,
        intent.SensitiveInformationTypePublisher,
        intent.Mode,
        intent.Activities,
        intent.Actions,
        false,
        false,
        DateTimeOffset.UtcNow);

    private sealed class RecordingAutomation : IPurviewSettingsAutomation
    {
        public Queue<PurviewProviderReadback<PurviewKnowYourDataReadback>>
            KnowYourDataReads
        { get; init; } = new();

        public Queue<PurviewProviderReadback<PurviewDlpProfileReadback>>
            DlpReads
        { get; init; } = new();

        public Exception? KnowYourDataMutationException { get; init; }
        public Exception? DlpPolicyMutationException { get; init; }
        public Exception? DlpRuleMutationException { get; init; }
        public List<PurviewSettingsAutomationMutation> Mutations { get; } = [];
        public List<string> Calls { get; } = [];

        public Task<PurviewProviderReadback<PurviewKnowYourDataReadback>>
            ReadKnowYourDataAsync(
                PurviewKnowYourDataIntent intent,
                CancellationToken cancellationToken)
        {
            Calls.Add("ReadKyd");
            return Task.FromResult(KnowYourDataReads.Dequeue());
        }

        public Task CreateKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken)
        {
            Calls.Add("CreateKyd");
            Mutations.Add(PurviewSettingsAutomationMutation.CreateKnowYourData);
            return KnowYourDataMutationException is null
                ? Task.CompletedTask
                : Task.FromException(KnowYourDataMutationException);
        }

        public Task<PurviewProviderReadback<PurviewDlpProfileReadback>>
            ReadDlpProfileAsync(
                PurviewDlpProfileIntent intent,
                CancellationToken cancellationToken)
        {
            Calls.Add("ReadDlp");
            return Task.FromResult(DlpReads.Dequeue());
        }

        public Task CreateDlpPolicyAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken)
        {
            Calls.Add("CreateDlpPolicy");
            Mutations.Add(PurviewSettingsAutomationMutation.CreateDlpPolicy);
            return DlpPolicyMutationException is null
                ? Task.CompletedTask
                : Task.FromException(DlpPolicyMutationException);
        }

        public Task CreateDlpRuleAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken)
        {
            Calls.Add("CreateDlpRule");
            Mutations.Add(PurviewSettingsAutomationMutation.CreateDlpRule);
            return DlpRuleMutationException is null
                ? Task.CompletedTask
                : Task.FromException(DlpRuleMutationException);
        }
    }
}

public sealed class PurviewReadinessEvaluatorTests
{
    [Fact]
    public void Evaluate_ExactReadbackAlone_IsNotRuntimeReady()
    {
        var now = DateTimeOffset.UtcNow;
        var readiness = PurviewReadinessEvaluator.Evaluate(
            new PurviewReadinessEvidence(
                ProtectionCapabilityStatus.Installed,
                ProtectionReadbackStatus.Ready,
                ProtectionPropagationStatus.Pending,
                ProtectionTokenRoleStatus.PendingRefresh,
                ProtectionRuntimeVerdictStatus.NotChecked,
                ExactReadbackAtUtc: now),
            now);

        readiness.Readback.Should().Be(ProtectionReadbackStatus.Ready);
        readiness.Propagation.Should().Be(ProtectionPropagationStatus.Pending);
        readiness.TokenRoles.Should().Be(ProtectionTokenRoleStatus.PendingRefresh);
        readiness.RuntimeVerdict.Should().Be(ProtectionRuntimeVerdictStatus.NotChecked);
        readiness.IsReady.Should().BeFalse();
    }

    [Fact]
    public void Evaluate_OnlyIndependentReadyEvidence_IsReady()
    {
        var now = DateTimeOffset.UtcNow;
        var readiness = PurviewReadinessEvaluator.Evaluate(
            new PurviewReadinessEvidence(
                ProtectionCapabilityStatus.Installed,
                ProtectionReadbackStatus.Ready,
                ProtectionPropagationStatus.Ready,
                ProtectionTokenRoleStatus.Ready,
                ProtectionRuntimeVerdictStatus.Ready,
                now,
                now,
                now,
                now,
                now),
            now);

        readiness.Should().Be(ProtectionReadiness.Ready);
        readiness.IsReady.Should().BeTrue();
    }

    [Fact]
    public void Evaluate_ReadyLabelsWithoutIndependentEvidence_FailClosed()
    {
        var readiness = PurviewReadinessEvaluator.Evaluate(new PurviewReadinessEvidence(
            ProtectionCapabilityStatus.Installed,
            ProtectionReadbackStatus.Ready,
            ProtectionPropagationStatus.Ready,
            ProtectionTokenRoleStatus.Ready,
            ProtectionRuntimeVerdictStatus.Ready));

        readiness.Readback.Should().Be(ProtectionReadbackStatus.Failed);
        readiness.Propagation.Should().Be(ProtectionPropagationStatus.Failed);
        readiness.TokenRoles.Should().Be(ProtectionTokenRoleStatus.Failed);
        readiness.RuntimeVerdict.Should().Be(ProtectionRuntimeVerdictStatus.Failed);
        readiness.IsReady.Should().BeFalse();
    }
}

public sealed class PurviewTokenRoleAttestorTests
{
    private static readonly Guid TenantId =
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");

    [Fact]
    public async Task Attest_ReportsReadyOnlyWhenEveryRequiredRoleIsInCurrentCredential()
    {
        var expiresAt = DateTimeOffset.UtcNow.AddMinutes(30);
        var source = new StaticRoleSource(
            new HashSet<string>(
                PurviewTokenRoleAttestor.RequiredRoles,
                StringComparer.Ordinal),
            expiresAt,
            TenantId);
        var attestor = new PurviewTokenRoleAttestor(source);

        var result = await attestor.AttestAsync(TenantId, CancellationToken.None);

        result.Status.Should().Be(ProtectionTokenRoleStatus.Ready);
        result.CredentialExpiresAtUtc.Should().Be(expiresAt);
        result.FailureCode.Should().BeNull();
    }

    [Fact]
    public async Task Attest_MissingRole_RemainsSeparateFailClosedEvidence()
    {
        var source = new StaticRoleSource(
            new HashSet<string>(StringComparer.Ordinal)
            {
                "Content.Process.User",
                "ContentActivity.Write"
            },
            DateTimeOffset.UtcNow.AddMinutes(30),
            TenantId);
        var attestor = new PurviewTokenRoleAttestor(source);

        var result = await attestor.AttestAsync(TenantId, CancellationToken.None);

        result.Status.Should().Be(ProtectionTokenRoleStatus.MissingRequiredRoles);
        result.FailureCode.Should().Be("PURVIEW_TOKEN_REQUIRED_ROLES_MISSING");
    }

    [Fact]
    public async Task Attest_WrongTenant_FailsClosedEvenWithEveryRole()
    {
        var source = new StaticRoleSource(
            new HashSet<string>(
                PurviewTokenRoleAttestor.RequiredRoles,
                StringComparer.Ordinal),
            DateTimeOffset.UtcNow.AddMinutes(30),
            Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"));
        var attestor = new PurviewTokenRoleAttestor(source);

        var result = await attestor.AttestAsync(TenantId, CancellationToken.None);

        result.Status.Should().Be(ProtectionTokenRoleStatus.Failed);
        result.FailureCode.Should().Be("PURVIEW_TOKEN_TENANT_MISMATCH");
    }

    private sealed class StaticRoleSource(
        IReadOnlySet<string> roles,
        DateTimeOffset expiresAtUtc,
        Guid tenantId) : IPurviewTokenRoleSource
    {
        public ValueTask<PurviewTokenRoleSnapshot> ReadAsync(
            CancellationToken cancellationToken) =>
            ValueTask.FromResult(new PurviewTokenRoleSnapshot(
                roles,
                expiresAtUtc,
                tenantId,
                "https://graph.microsoft.com"));
    }
}

public sealed class LegacyPurviewProvisioningCompatibilityTests
{
    [Fact]
    public void LegacyProvisioningAdapter_IsNeverAnAuthoringCapability()
    {
        var client = new PowerShellPurviewPolicyProvisioningClient(
            Options.Create(new PurviewOptions
            {
                Enabled = true,
                PolicyProvisioningEnabled = true
            }),
            NullLogger<PowerShellPurviewPolicyProvisioningClient>.Instance);

        client.IsEnabled.Should().BeFalse();
    }

    [Fact]
    public async Task EnsureWithoutPersistedProviderIds_DoesNotAuthorFromProvisioning()
    {
        var options = Options.Create(new PurviewOptions
        {
            Enabled = true,
            PolicyProvisioningEnabled = true
        });
        var client = new PowerShellPurviewPolicyProvisioningClient(
            options,
            NullLogger<PowerShellPurviewPolicyProvisioningClient>.Instance);
        var request = new PurviewPolicyProvisioningRequest(
            Guid.NewGuid(),
            "Legacy",
            "Legacy",
            "Enforce",
            "collection",
            "policy",
            "rule",
            Guid.NewGuid().ToString("D"),
            "Blueprint",
            ExpectedPriorDlpBlueprintApplicationIds: [],
            ExpectedDlpBlueprintApplicationIds: []);

        var action = () => client.EnsureProfileAssignmentAsync(
            request,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be(
            "PURVIEW_SETTINGS_OWNS_POLICY_AUTHORING");
    }
}

public sealed class PurviewManagedIdentityCertificateTests
{
    [Fact]
    public void CertificateCredentialFactory_UsesManagedIdentityOnly()
    {
        var systemAssigned = PowerShellPurviewSettingsAutomation
            .CreateManagedIdentityCredential(null);
        var userAssigned = PowerShellPurviewSettingsAutomation
            .CreateManagedIdentityCredential(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");

        systemAssigned.GetType().Name.Should().Be("ManagedIdentityCredential");
        userAssigned.GetType().Name.Should().Be("ManagedIdentityCredential");
    }

    [Theory]
    [InlineData("https://gateway.vault.azure.net/certificates/purview")]
    [InlineData("https://gateway.vault.azure.net/secrets/purview/version")]
    [InlineData("https://gateway.vault.azure.net/secrets/purview%2Fother")]
    [InlineData("https://example.test/secrets/purview")]
    public void CertificatePath_MustBeOneVersionlessKeyVaultSecret(string value)
    {
        var action = () => PowerShellPurviewSettingsAutomation
            .ParseApprovedCertificateSecretUri(value);

        action.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be(
                "PURVIEW_SETTINGS_CERTIFICATE_URI_INVALID");
    }
}

public sealed class PowerShellPurviewSettingsAutomationProcessTests
{
    [Fact]
    public async Task WaitForExitOrTerminate_CallerCancellation_KillsAndAwaitsChild()
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = OperatingSystem.IsWindows() ? "pwsh.exe" : "pwsh",
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };
        process.StartInfo.ArgumentList.Add("-NoLogo");
        process.StartInfo.ArgumentList.Add("-NoProfile");
        process.StartInfo.ArgumentList.Add("-Command");
        process.StartInfo.ArgumentList.Add("Start-Sleep -Seconds 30");
        process.Start().Should().BeTrue();
        using var cancellation = new CancellationTokenSource(
            TimeSpan.FromMilliseconds(500));

        var action = () => PowerShellPurviewSettingsAutomation
            .WaitForExitOrTerminateAsync(process, cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        process.HasExited.Should().BeTrue();
    }
}

public sealed class PurviewAutomationCapabilityBindingTests
{
    private static readonly Guid ApplicationId =
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    private static readonly Guid ServicePrincipalId =
        Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");

    [Fact]
    public void Bind_ExactBootstrapFactsAndRuntimeReference_AreAccepted()
    {
        var binding = PurviewAutomationCapabilityBindingValidator.Bind(
            CreateCapabilityIdentifiers(),
            CreateOptions());

        binding.ApplicationId.Value.Should().Be(ApplicationId);
        binding.ServicePrincipalObjectId.Value.Should().Be(ServicePrincipalId);
        binding.KeyVaultResourceId.Should().Be(
            "/subscriptions/cccccccc-cccc-4ccc-8ccc-cccccccccccc/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gatewayvault");
        binding.KeyVaultHost.Should().Be("gatewayvault.vault.azure.net");
        binding.CertificateName.Should().Be("purview-automation");
        binding.CertificateSecretUri.AbsoluteUri.Should().Be(
            "https://gatewayvault.vault.azure.net/secrets/purview-automation");
    }

    [Fact]
    public void Bind_MissingServicePrincipalFact_IsRejected()
    {
        var identifiers = CreateCapabilityIdentifiers() with
        {
            PurviewAutomationServicePrincipalObjectId = null
        };

        var action = () => PurviewAutomationCapabilityBindingValidator.Bind(
            identifiers,
            CreateOptions());

        action.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be(
                "PURVIEW_AUTOMATION_CAPABILITY_BINDING_INCOMPLETE");
    }

    [Fact]
    public void Bind_SubstitutedApplicationId_IsRejected()
    {
        var options = CreateOptions();
        options.PolicyProvisioningApplicationId =
            "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

        var action = () => PurviewAutomationCapabilityBindingValidator.Bind(
            CreateCapabilityIdentifiers(),
            options);

        action.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be(
                "PURVIEW_AUTOMATION_APPLICATION_MISMATCH");
    }

    [Theory]
    [InlineData(
        "https://differentvault.vault.azure.net/secrets/purview-automation",
        "PURVIEW_AUTOMATION_KEY_VAULT_MISMATCH")]
    [InlineData(
        "https://gatewayvault.vault.azure.net/secrets/substituted-certificate",
        "PURVIEW_AUTOMATION_CERTIFICATE_MISMATCH")]
    [InlineData(
        "https://gatewayvault.vault.azure.net/secrets/purview-automation/version",
        "PURVIEW_SETTINGS_CERTIFICATE_URI_INVALID")]
    [InlineData(
        "https://gatewayvault.vault.azure.net/secrets/purview-automation/",
        "PURVIEW_SETTINGS_CERTIFICATE_URI_INVALID")]
    public void Bind_SubstitutedVaultCertificateOrSecretReference_IsRejected(
        string secretUri,
        string failureCode)
    {
        var options = CreateOptions();
        options.PolicyProvisioningCertificateSecretUri = secretUri;

        var action = () => PurviewAutomationCapabilityBindingValidator.Bind(
            CreateCapabilityIdentifiers(),
            options);

        action.Should().Throw<PurviewPolicyException>()
            .Which.FailureCode.Should().Be(failureCode);
    }

    private static ProtectionCapabilityResourceIdentifiers
        CreateCapabilityIdentifiers() => new(
            PurviewAutomationApplicationId:
                new ApplicationClientId(ApplicationId),
            PurviewAutomationServicePrincipalObjectId:
                new ServicePrincipalObjectId(ServicePrincipalId),
            KeyVaultResourceId:
                "/subscriptions/cccccccc-cccc-4ccc-8ccc-cccccccccccc/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gatewayvault",
            CertificateName: "purview-automation");

    private static PurviewOptions CreateOptions() => new()
    {
        PolicyProvisioningApplicationId = ApplicationId.ToString("D"),
        PolicyProvisioningCertificateSecretUri =
            "https://gatewayvault.vault.azure.net/secrets/purview-automation"
    };
}

public sealed class PurviewAutomationArtifactTests
{
    [Fact]
    public void InteractiveCompanion_UsesOfficialNonEchoingTenantAndUserReadback()
    {
        var script = ReadAutomationScript(PurviewCompanionCommand.ScriptFileName);

        script.Should().Contain("Connect-IPPSSession");
        script.Should().Contain("-ShowBanner:$false");
        script.Should().Contain("Out-Null");
        script.Should().Contain("Get-ConnectionInformation");
        script.Should().Contain("ExternalDirectoryObjectId");
        script.Should().Contain("Get-DlpSensitiveInformationType");
        script.Should().NotContain("-AccessToken");
    }

    [Fact]
    public void LegacyProvisioningArtifact_RequiresVerifyOnlyBeforeProviderConnection()
    {
        var script = ReadAutomationScript("Ensure-PurviewPolicyProfile.ps1");

        script.Should().Contain(
            "New Purview policy authoring is available only through reviewed Gateway Settings operations.");
        script.IndexOf("if (-not $VerifyOnly)", StringComparison.Ordinal)
            .Should().BeLessThan(
                script.IndexOf("Connect-IPPSSession", StringComparison.Ordinal));
    }

    [Fact]
    public void SettingsAutomation_KeepsKydAndDlpLocationsIndependent()
    {
        var script = ReadAutomationScript("Invoke-PurviewSettingsOperation.ps1");

        script.Should().Contain(PurviewPolicyLocationContract
            .EnterpriseAiAppsCollectionLocationId);
        script.Should().Contain("-Type 'Group'");
        script.Should().Contain("-Type 'Individual'");
        script.Should().Contain("CreateDlpPolicy");
        script.Should().Contain("CreateDlpRule");
    }

    [Fact]
    public void SettingsAutomation_UsesProviderUpdateCmdletsByExactIdentity()
    {
        var script = ReadAutomationScript("Invoke-PurviewSettingsOperation.ps1");

        script.Should().Contain("Set-FeatureConfiguration");
        script.Should().Contain("Set-DlpCompliancePolicy");
        script.Should().Contain("Set-DlpComplianceRule");
        script.Should().Contain("-Identity $policy.Identity");
        script.Should().Contain("-Identity $rule.Identity");
        script.Should().Contain(
            "Know Your Data update requires persisted provider-ID authority.");
        script.Should().Contain(
            "DLP policy update requires persisted provider-ID authority.");
        script.Should().Contain(
            "A provider-ID-bound DLP rule is absent and cannot be recreated.");
    }

    private static string ReadAutomationScript(string name) =>
        File.ReadAllText(Path.Combine(
            AppContext.BaseDirectory,
            "Automation",
            name));
}
