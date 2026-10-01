using Gateway.Application.Agents.Validators;
using Gateway.Contracts.Dtos;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class RegistrationValidationTests
{
    [Theory]
    [InlineData("CreateNew", null, "Reusable blueprint", true)]
    [InlineData("UseExisting", "00000000-0000-4000-8000-000000000004", null, true)]
    [InlineData("UseExisting", "00000000-0000-0000-0000-000000000000", null, false)]
    [InlineData("UseExisting", "not-a-guid", null, false)]
    [InlineData("UseExisting", "00000000-0000-4000-8000-000000000004", "Conflicting name", false)]
    [InlineData("CreateNew", "00000000-0000-4000-8000-000000000004", "Conflicting ID", false)]
    [InlineData("CreateNew", null, "", false)]
    [InlineData("Legacy", null, null, false)]
    public void Blueprint_selection_has_exact_mutually_exclusive_shape(
        string mode, string? objectId, string? name, bool valid)
    {
        var result = new RegisterAgentValidator().Validate(
            TestData.Registration(blueprint: new(mode, objectId, name)));
        Assert.Equal(valid, result.IsValid);
    }

    [Fact]
    public void Conflicting_observability_destinations_are_rejected()
    {
        var request = TestData.Registration() with
        {
            Features = new AgentFeaturesDto("Disabled", false, null, Agent365ObservabilityEnabled: true)
        };
        var result = new RegisterAgentValidator().Validate(request);
        Assert.False(result.IsValid);
        Assert.Contains(result.Errors, error => error.PropertyName == "Features");
    }
}
