using System.Reflection;
using FluentAssertions;
using FluentValidation;
using MediatR;
using NetArchTest.Rules;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Validates naming conventions across the codebase.
/// Commands, Queries, Handlers, Validators, Controllers, and Exceptions
/// must follow consistent suffixing rules.
/// </summary>
public class NamingConventionTests
{
    private static readonly Assembly ApplicationAssembly =
        typeof(Gateway.Application.DependencyInjection).Assembly;

    private static readonly Assembly ApiAssembly =
        typeof(Gateway.Api.Authorization.AuthorizationPolicies).Assembly;

    // ---------------------------------------------------------------
    // 1. Commands end with "Command"
    // ---------------------------------------------------------------

    [Fact]
    public void Commands_Should_HaveNameEndingWith_Command()
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequest<>))
            .And()
            .ResideInNamespaceContaining("Commands")
            .Should()
            .HaveNameEndingWith("Command")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All IRequest<> types in Commands namespaces should end with 'Command'. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 2. Queries end with "Query"
    // ---------------------------------------------------------------

    [Fact]
    public void Queries_Should_HaveNameEndingWith_Query()
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequest<>))
            .And()
            .ResideInNamespaceContaining("Queries")
            .Should()
            .HaveNameEndingWith("Query")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All IRequest<> types in Queries namespaces should end with 'Query'. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 3. Handlers end with "Handler"
    // ---------------------------------------------------------------

    [Fact]
    public void Handlers_Should_HaveNameEndingWith_Handler()
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequestHandler<,>))
            .Should()
            .HaveNameEndingWith("Handler")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All IRequestHandler<,> implementations should end with 'Handler'. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 4. Validators end with "Validator"
    // ---------------------------------------------------------------

    [Fact]
    public void Validators_Should_HaveNameEndingWith_Validator()
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .That()
            .Inherit(typeof(AbstractValidator<>))
            .Should()
            .HaveNameEndingWith("Validator")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All AbstractValidator<> implementations should end with 'Validator'. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 5. Controllers end with "Controller"
    // ---------------------------------------------------------------

    [Fact]
    public void Controllers_Should_HaveNameEndingWith_Controller()
    {
        var result = Types.InAssembly(ApiAssembly)
            .That()
            .ResideInNamespace("Gateway.Api.Controllers")
            .Should()
            .HaveNameEndingWith("Controller")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All types in Gateway.Api.Controllers should end with 'Controller'. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 6. Exceptions end with "Exception"
    // ---------------------------------------------------------------

    [Fact]
    public void Exceptions_Should_HaveNameEndingWith_Exception()
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .That()
            .Inherit(typeof(Exception))
            .And()
            .ResideInNamespace("Gateway.Application.Exceptions")
            .Should()
            .HaveNameEndingWith("Exception")
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All Exception types in Application.Exceptions should end with 'Exception'. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // Supplemental: verify type populations are non-empty so tests
    // are not vacuously true
    // ---------------------------------------------------------------

    [Fact]
    public void Application_Should_ContainCommands()
    {
        var types = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequest<>))
            .And()
            .ResideInNamespaceContaining("Commands")
            .GetTypes();

        types.Should().NotBeEmpty(
            "the Application assembly must contain Command types for naming tests to be meaningful");
    }

    [Fact]
    public void Application_Should_ContainQueries()
    {
        var types = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequest<>))
            .And()
            .ResideInNamespaceContaining("Queries")
            .GetTypes();

        types.Should().NotBeEmpty(
            "the Application assembly must contain Query types for naming tests to be meaningful");
    }

    [Fact]
    public void Application_Should_ContainHandlers()
    {
        var types = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequestHandler<,>))
            .GetTypes();

        types.Should().NotBeEmpty(
            "the Application assembly must contain Handler types for naming tests to be meaningful");
    }

    [Fact]
    public void Application_Should_ContainValidators()
    {
        var types = Types.InAssembly(ApplicationAssembly)
            .That()
            .Inherit(typeof(AbstractValidator<>))
            .GetTypes();

        types.Should().NotBeEmpty(
            "the Application assembly must contain Validator types for naming tests to be meaningful");
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
