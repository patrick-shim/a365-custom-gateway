using System.Reflection;
using FluentAssertions;
using NetArchTest.Rules;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Validates that the modular monolith dependency rules are respected.
/// Each module has strict boundaries on what it may reference.
/// </summary>
public class ModuleDependencyTests
{
    private static readonly Assembly DomainAssembly =
        typeof(Gateway.Domain.Entities.AgentRegistration).Assembly;

    private static readonly Assembly ContractsAssembly =
        typeof(Gateway.Contracts.ErrorCodes).Assembly;

    private static readonly Assembly ApplicationAssembly =
        typeof(Gateway.Application.DependencyInjection).Assembly;

    private static readonly Assembly InfrastructureAssembly =
        typeof(Gateway.Infrastructure.DependencyInjection).Assembly;

    private static readonly Assembly Agent365Assembly =
        typeof(Gateway.Agent365.DependencyInjection).Assembly;

    private static readonly Assembly PurviewAssembly =
        typeof(Gateway.Purview.DependencyInjection).Assembly;

    private static readonly Assembly ObservabilityAssembly =
        typeof(Gateway.Observability.DependencyInjection).Assembly;

    private static readonly Assembly ApiAssembly =
        typeof(Gateway.Api.Authorization.AuthorizationPolicies).Assembly;

    // ---------------------------------------------------------------
    // Rule 1: Domain has no dependencies on any other gateway module
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Gateway.Application")]
    [InlineData("Gateway.Infrastructure")]
    [InlineData("Gateway.Api")]
    [InlineData("Gateway.Contracts")]
    [InlineData("Gateway.Agent365")]
    [InlineData("Gateway.Purview")]
    [InlineData("Gateway.Observability")]
    public void DomainModule_Should_NotHaveDependencyOn(string forbiddenNamespace)
    {
        var result = Types.InAssembly(DomainAssembly)
            .ShouldNot()
            .HaveDependencyOn(forbiddenNamespace)
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Domain must not depend on {forbiddenNamespace}, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Rule 2: Contracts has no dependencies on any other gateway module
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Gateway.Domain")]
    [InlineData("Gateway.Application")]
    [InlineData("Gateway.Infrastructure")]
    [InlineData("Gateway.Api")]
    [InlineData("Gateway.Agent365")]
    [InlineData("Gateway.Purview")]
    [InlineData("Gateway.Observability")]
    public void ContractsModule_Should_NotHaveDependencyOn(string forbiddenNamespace)
    {
        var result = Types.InAssembly(ContractsAssembly)
            .ShouldNot()
            .HaveDependencyOn(forbiddenNamespace)
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Contracts must not depend on {forbiddenNamespace}, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Rule 3: Application does not depend on Infrastructure, Api,
    //         Agent365, or Purview
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Gateway.Infrastructure")]
    [InlineData("Gateway.Api")]
    [InlineData("Gateway.Agent365")]
    [InlineData("Gateway.Purview")]
    public void ApplicationModule_Should_NotHaveDependencyOn(string forbiddenNamespace)
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .ShouldNot()
            .HaveDependencyOn(forbiddenNamespace)
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Application must not depend on {forbiddenNamespace}, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Rule 4: Infrastructure does not depend on Api
    // ---------------------------------------------------------------

    [Fact]
    public void InfrastructureModule_Should_NotDependOn_Api()
    {
        var result = Types.InAssembly(InfrastructureAssembly)
            .ShouldNot()
            .HaveDependencyOn("Gateway.Api")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Infrastructure must not depend on Gateway.Api, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Rule 5: Agent365 does not depend on Application, Infrastructure,
    //         or Api
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Gateway.Application")]
    [InlineData("Gateway.Infrastructure")]
    [InlineData("Gateway.Api")]
    public void Agent365Module_Should_NotHaveDependencyOn(string forbiddenNamespace)
    {
        var result = Types.InAssembly(Agent365Assembly)
            .ShouldNot()
            .HaveDependencyOn(forbiddenNamespace)
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Agent365 must not depend on {forbiddenNamespace}, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Rule 6: Purview does not depend on Infrastructure or Api
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Gateway.Infrastructure")]
    [InlineData("Gateway.Api")]
    public void PurviewModule_Should_NotHaveDependencyOn(string forbiddenNamespace)
    {
        var result = Types.InAssembly(PurviewAssembly)
            .ShouldNot()
            .HaveDependencyOn(forbiddenNamespace)
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Purview must not depend on {forbiddenNamespace}, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Rule 7: Observability does not depend on Infrastructure or Api
    // ---------------------------------------------------------------

    [Theory]
    [InlineData("Gateway.Infrastructure")]
    [InlineData("Gateway.Api")]
    [InlineData("Gateway.Application")]
    public void ObservabilityModule_Should_NotHaveDependencyOn(string forbiddenNamespace)
    {
        var result = Types.InAssembly(ObservabilityAssembly)
            .ShouldNot()
            .HaveDependencyOn(forbiddenNamespace)
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"Observability must not depend on {forbiddenNamespace}, " +
            $"but these types violate the rule: " +
            $"{FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    private static string FormatFailingTypes(TestResult result)
    {
        var failingNames = result.FailingTypes?
            .Select(t => t.FullName)
            .ToList();

        return failingNames is { Count: > 0 }
            ? string.Join(", ", failingNames)
            : "(none)";
    }
}
