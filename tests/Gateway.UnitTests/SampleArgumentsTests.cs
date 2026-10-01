using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class SampleArgumentsTests
{
    [Fact]
    public void Handoff_command_uses_explicit_tenant_user_and_no_key_argument()
    {
        Assert.True(Arguments.TryParse(
            ["--api-base-url", "https://sample-gate.invalid/gateway", "--external-agent-id", "synthetic-child-agent",
                "--tenant-user-object-id", TestData.TenantUser, "--message", "Synthetic prompt"],
            out var options, out var error));

        Assert.Equal(string.Empty, error);
        Assert.Equal(new Uri("https://sample-gate.invalid/gateway/"), options.ApiBaseUrl);
        Assert.Equal(Guid.Parse(TestData.TenantUser), options.TenantUserObjectId);
        Assert.Equal("Synthetic prompt", options.Message);
    }

    [Theory]
    [InlineData("--key")]
    [InlineData("--gateway-key")]
    [InlineData("--access-key")]
    [InlineData("--api-key")]
    public void Key_arguments_are_rejected_without_echoing_their_value(string flag)
    {
        Assert.False(Arguments.TryParse(
            ["--api-base-url", "https://sample-gate.invalid/", "--external-agent-id", "synthetic-child-agent",
                "--tenant-user-object-id", TestData.TenantUser, flag, SampleGateFixture.SyntheticKey],
            out _, out var error));

        Assert.Equal("Unknown argument.", error);
        Assert.DoesNotContain(SampleGateFixture.SyntheticKey, error);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-an-id")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public void Missing_or_invalid_user_identity_is_not_invented(string user)
    {
        Assert.False(Arguments.TryParse(
            ["--api-base-url", "https://sample-gate.invalid/", "--external-agent-id", "synthetic-child-agent",
                "--tenant-user-object-id", user], out _, out var error));

        Assert.Equal("--tenant-user-object-id must be a non-empty GUID.", error);
    }
}
