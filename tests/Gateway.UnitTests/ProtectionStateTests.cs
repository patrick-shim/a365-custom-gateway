using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class ProtectionStateTests
{
    [Theory]
    [InlineData("capability")]
    [InlineData("readback")]
    [InlineData("propagation")]
    [InlineData("token-roles")]
    [InlineData("runtime")]
    public void Every_readiness_dimension_must_be_verified(string dimension)
    {
        Assert.True(ProtectionReadiness.Ready.IsReady);
        var readiness = dimension switch
        {
            "capability" => ProtectionReadiness.Ready with { Capability = ProtectionCapabilityStatus.Unavailable },
            "readback" => ProtectionReadiness.Ready with { Readback = ProtectionReadbackStatus.Stale },
            "propagation" => ProtectionReadiness.Ready with { Propagation = ProtectionPropagationStatus.Pending },
            "token-roles" => ProtectionReadiness.Ready with { TokenRoles = ProtectionTokenRoleStatus.MissingRequiredRoles },
            _ => ProtectionReadiness.Ready with { RuntimeVerdict = ProtectionRuntimeVerdictStatus.NotChecked }
        };
        Assert.False(readiness.IsReady);
    }

    [Fact]
    public void Installed_historical_evidence_is_not_current_runtime_certification()
    {
        var profile = TestData.ReadyProfile();
        Assert.True(profile.HasRuntimeEvidenceFor(profile.BlueprintApplicationId, TestData.Now));
        Assert.False(profile.IsExactlyReadyFor(profile.BlueprintApplicationId, TestData.Now));
        Assert.True(profile.IsExactlyReadyFor(profile.BlueprintApplicationId, TestData.Now, runtimeCertificationCurrent: true));
        Assert.False(profile.IsExactlyReadyFor(profile.BlueprintApplicationId, TestData.Now.AddHours(1), true));
        Assert.False(profile.IsExactlyReadyFor(new(Guid.NewGuid()), TestData.Now, true));
    }

    [Theory]
    [InlineData("off", PurviewEffectiveEnablementStatus.Disabled)]
    [InlineData("blueprint", PurviewEffectiveEnablementStatus.BlueprintRequired)]
    [InlineData("profile", PurviewEffectiveEnablementStatus.ProfileRequired)]
    [InlineData("wrong-profile", PurviewEffectiveEnablementStatus.ProfileMismatch)]
    [InlineData("wrong-blueprint", PurviewEffectiveEnablementStatus.ProfileMismatch)]
    [InlineData("uncertified", PurviewEffectiveEnablementStatus.ProfileNotReady)]
    [InlineData("ready", PurviewEffectiveEnablementStatus.Ready)]
    public void Requested_and_effectively_enabled_are_distinct(string scenario, PurviewEffectiveEnablementStatus expected)
    {
        var profile = TestData.ReadyProfile();
        var actual = PurviewEffectiveProtection.Evaluate(
            scenario != "off",
            scenario == "blueprint" ? null : scenario == "wrong-blueprint" ? new(Guid.NewGuid()) : profile.BlueprintApplicationId,
            scenario == "profile" ? null : scenario == "wrong-profile" ? new(Guid.NewGuid()) : profile.Id,
            profile, TestData.Now, runtimeCertificationCurrent: scenario != "uncertified");
        Assert.Equal(expected, actual.Status);
        Assert.Equal(expected == PurviewEffectiveEnablementStatus.Ready, actual.IsEnabled);
        Assert.Equal(scenario != "off", actual.IsRequested);
    }

    [Theory]
    [InlineData(PurviewPolicyMode.Disabled, PurviewDlpProfileStatus.Disabled)]
    [InlineData(PurviewPolicyMode.SimulationWithTips, PurviewDlpProfileStatus.SimulationReady)]
    [InlineData(PurviewPolicyMode.SimulationWithoutTips, PurviewDlpProfileStatus.SimulationReady)]
    public void Verified_non_enforcing_configuration_never_claims_runtime_enforcement(
        PurviewPolicyMode mode, PurviewDlpProfileStatus status)
    {
        var profile = TestData.ReadyProfile();
        profile.PolicyMode = mode;
        profile.Mode = PurviewMode.AuditOnly;
        profile.Status = status;
        Assert.True(profile.HasVerifiedNonEnforcingConfiguration);
        Assert.False(profile.IsExactlyReadyFor(profile.BlueprintApplicationId, TestData.Now, true));
        profile.LastReadbackAtUtc = null;
        Assert.False(profile.HasVerifiedNonEnforcingConfiguration);
    }
}
