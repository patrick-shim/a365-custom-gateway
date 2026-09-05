using FluentAssertions;
using Gateway.Application.Protection;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class ProtectionRequiredActionCodeTests
{
    [Fact]
    public void CompleteTenantConnectionActionMatchesTheTypedUiContract()
    {
        ProtectionRequiredActionCodes.CompletePurviewTenantConnection
            .Should().Be("CompletePurviewTenantConnection");
    }
}
