using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class ProjectNameGeneratorTests
{
    [Fact]
    public void FromBytes_ProducesDeterministicSevenCharacterSafeName()
    {
        ProjectNameGenerator.FromBytes([0x01, 0xA2, 0xBC])
            .Should().Be("gw01a2b");
    }

    [Fact]
    public void Create_ProducesSchemaCompatibleCollisionResistantName()
    {
        var names = Enumerable.Range(0, 16)
            .Select(_ => new ProjectNameGenerator().Create())
            .ToArray();

        names.Should().OnlyContain(name =>
            name.Length == 7 &&
            System.Text.RegularExpressions.Regex.IsMatch(name, "^[a-z][a-z0-9]{1,7}$"));
    }

    [Fact]
    public void WizardState_DerivesTenantLevelNamesFromTheRandomizedProject()
    {
        var state = new SetupWizardState(new FixedProjectNameGenerator());

        state.Form.ProjectName.Should().Be("gwfixed");
        state.Form.ResourceGroupName.Should().Be("rg-gwfixed-dev");
        state.Form.SeedBlueprintName.Should().Be("A365 Gateway gwfixed dev");
        state.Form.PurviewCollectionPolicyName.Should().Be("A365 Gateway gwfixed AI collection");
        state.Form.PurviewDlpPolicyName.Should().Be("A365 Gateway gwfixed inline DLP");
        state.Form.PurviewDlpRuleName.Should().Be("A365 Gateway gwfixed inline DLP rule");
    }

    private sealed class FixedProjectNameGenerator : IProjectNameGenerator
    {
        public string Create() => "gwfixed";
    }
}
