using FluentAssertions;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts.Dtos;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using NSubstitute;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class ProtectionDlpActionContractTests
{
    [Theory]
    [InlineData("AuditOnly")]
    [InlineData("Enforce")]
    public async Task ReviewRejectsUnsupportedActionsBeforePersistingAnOperation(string mode)
    {
        var fixture = new ReviewFixture();
        var profile = fixture.Profile;
        var request = new ReviewPurviewDlpProfileOperationRequest(null, profile.PurviewTenantConnectionId,
            profile.BlueprintApplicationId.Value, "Synthetic profile",
            new(profile.InventoryGenerationId.Value, profile.SensitiveInformationTypeId.Value, profile.SensitiveInformationTypeName),
            mode, ["UploadText", "DownloadText"],
            [new("UploadText", mode == "Enforce" ? "Block" : "Audit"), new("DownloadText", "Audit")], "*");

        var action = () => fixture.Handler.Handle(new ReviewPurviewDlpProfileCommand(
            fixture.Actor, request, Guid.NewGuid()), CancellationToken.None);

        (await action.Should().ThrowAsync<ValidationException>()).Which.Errors.Should().ContainKey("Actions");
        await fixture.Operations.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Theory]
    [InlineData(PurviewMode.AuditOnly, false)]
    [InlineData(PurviewMode.Enforce, true)]
    public async Task RuntimeReviewRequiresEnforceModeBeforePersistingAnOperation(PurviewMode mode, bool accepted)
    {
        var fixture = new ReviewFixture();
        var profile = fixture.Profile;
        profile.Mode = mode;
        var version = ProtectionRowVersion.Encode(profile.RowVersion, profile.Id.Value, profile.UpdatedAtUtc);
        var action = () => fixture.Handler.Handle(new ReviewValidatePurviewDlpRuntimeCommand(fixture.Actor,
            profile.Id.Value, new(profile.Id.Value, version), Guid.NewGuid()), CancellationToken.None);

        if (accepted)
        {
            await action.Should().NotThrowAsync();
            await fixture.Operations.Received(1).AddAsync(Arg.Any<ProtectionAdminOperation>(), Arg.Any<CancellationToken>());
        }
        else
        {
            (await action.Should().ThrowAsync<DomainException>()).Which.ErrorCode.Should().Be(ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
            await fixture.Operations.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
            await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
        }
    }

    [Theory]
    [InlineData("AuditOnly")]
    [InlineData("Enforce")]
    public void FormerSettingsActionsAreRejectedByApi(string mode)
    {
        PurviewDlpRuleActionDto[] actions =
        [
            new("UploadText", mode == "Enforce" ? "Block" : "Audit"),
            new("DownloadText", "Audit")
        ];
        var action = () => ProtectionAdministrationRules.ParseActions(actions,
            [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText]);

        action.Should().Throw<ValidationException>().Which.Errors.Should().ContainKey("Actions");
    }

    [Theory]
    [InlineData("UploadText", "Audit")]
    [InlineData("DownloadText", "Audit")]
    [InlineData("DownloadText", "Block")]
    [InlineData("0", "1")]
    public void UnsupportedOrNoncanonicalActionIsRejected(string activity, string value)
    {
        var action = () => ProtectionAdministrationRules.ParseActions([new(activity, value)],
            [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText]);

        action.Should().Throw<ValidationException>().Which.Errors.Should().ContainKey("Actions");
    }

    [Theory]
    [InlineData("AuditOnly")]
    [InlineData("Enforce")]
    public void SupportedUploadActionIsIndependentOfPolicyMode(string mode)
    {
        ProtectionAdministrationRules.ParseMode(mode).ToString().Should().Be(mode);
        ProtectionAdministrationRules.ParseActions([new("UploadText", "Block")],
            [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText])
            .Should().ContainSingle().Which.Should().Be(
                new Gateway.Domain.Models.PurviewDlpRuleAction(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block));
    }

    private sealed class ReviewFixture
    {
        public IProtectionAdminOperationRepository Operations { get; } = Substitute.For<IProtectionAdminOperationRepository>();
        public IUnitOfWork UnitOfWork { get; } = Substitute.For<IUnitOfWork>();
        public PurviewDlpProfile Profile { get; }
        public ProtectionActor Actor { get; }
        public ProtectionReviewHandler Handler { get; }

        public ReviewFixture()
        {
            var now = DateTime.UtcNow;
            var readiness = new PurviewReadinessFixture();
            Profile = readiness.Seed(new PurviewDlpProfile
            {
                Id = new(Guid.NewGuid()),
                BlueprintApplicationId = new(Guid.NewGuid()),
                Mode = PurviewMode.Enforce,
                DisplayName = "Synthetic profile",
                Activities = [PurviewPolicyActivity.UploadText, PurviewPolicyActivity.DownloadText],
                Actions = [new(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)],
                LastReadbackAtUtc = now,
                UpdatedAtUtc = now,
                SensitiveInformationTypeSnapshotExpiresAtUtc = now.AddMinutes(10)
            });
            Actor = new(readiness.Connection.TenantId.Value, Guid.NewGuid().ToString("D"));
            var capabilities = Substitute.For<IProtectionCapabilityRepository>();
            capabilities.GetByKindAsync(ProtectionCapabilityKind.Purview, Arg.Any<CancellationToken>())
                .Returns(new ProtectionCapability
                {
                    Kind = ProtectionCapabilityKind.Purview,
                    Status = ProtectionCapabilityStatus.Installed,
                    LastReadbackAtUtc = now
                });
            var profiles = Substitute.For<IPurviewDlpProfileRepository>();
            profiles.GetByIdAsync(Profile.Id, Arg.Any<CancellationToken>()).Returns(Profile);
            Handler = new(capabilities, readiness.Connections, readiness.Inventory,
                Substitute.For<IPurviewKnowYourDataConfigurationRepository>(), profiles, Operations,
                Substitute.For<IAgentIdentityBlueprintCatalog>(), Substitute.For<IAuditEventRepository>(), UnitOfWork,
                new ProtectionOperationTokenService(TimeProvider.System), TimeProvider.System);
        }
    }
}
