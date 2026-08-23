using System.Reflection;
using FluentAssertions;
using MediatR;
using NetArchTest.Rules;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Validates sealing conventions across the codebase.
/// Handlers and leaf exceptions must be sealed. Value objects must be
/// readonly record structs.
/// </summary>
public class SealedClassConventionTests
{
    private static readonly Assembly ApplicationAssembly =
        typeof(Gateway.Application.DependencyInjection).Assembly;

    private static readonly Assembly DomainAssembly =
        typeof(Gateway.Domain.Entities.AgentRegistration).Assembly;

    // ---------------------------------------------------------------
    // 1. Handlers should be sealed
    // ---------------------------------------------------------------

    [Fact]
    public void Handlers_Should_BeSealed()
    {
        var result = Types.InAssembly(ApplicationAssembly)
            .That()
            .ImplementInterface(typeof(IRequestHandler<,>))
            .Should()
            .BeSealed()
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All IRequestHandler<,> implementations should be sealed. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 2. Exceptions should be sealed (excluding DomainException base)
    // ---------------------------------------------------------------

    [Fact]
    public void Exceptions_Should_BeSealed_When_NotBaseClass()
    {
        var exceptionTypes = Types.InAssembly(ApplicationAssembly)
            .That()
            .Inherit(typeof(Exception))
            .And()
            .ResideInNamespace("Gateway.Application.Exceptions")
            .GetTypes();

        exceptionTypes.Should().NotBeEmpty(
            "there should be exception types in Application.Exceptions");

        // DomainException serves as a base class and is intentionally
        // not sealed. All other exception types must be sealed.
        var leafExceptions = exceptionTypes
            .Where(t => t != typeof(Gateway.Application.Exceptions.DomainException))
            .ToList();

        leafExceptions.Should().NotBeEmpty(
            "there should be concrete exception types beyond DomainException");

        foreach (var type in leafExceptions)
        {
            type.IsSealed.Should().BeTrue(
                $"{type.Name} should be sealed because it is a leaf exception type");
        }
    }

    // ---------------------------------------------------------------
    // 3. Value objects should be readonly record structs
    // ---------------------------------------------------------------

    [Fact]
    public void ValueObjects_Should_BeReadonlyRecordStructs()
    {
        var valueObjectTypes = Types.InAssembly(DomainAssembly)
            .That()
            .ResideInNamespace("Gateway.Domain.ValueObjects")
            .GetTypes();

        valueObjectTypes.Should().NotBeEmpty(
            "there should be value object types in Domain.ValueObjects");

        foreach (var type in valueObjectTypes)
        {
            // Must be a struct (value type)
            type.IsValueType.Should().BeTrue(
                $"{type.Name} should be a value type (struct)");

            // readonly structs carry IsReadOnlyAttribute
            var hasReadonlyAttribute = type.CustomAttributes.Any(
                a => a.AttributeType.FullName ==
                     "System.Runtime.CompilerServices.IsReadOnlyAttribute");

            hasReadonlyAttribute.Should().BeTrue(
                $"{type.Name} should be readonly (must have IsReadOnlyAttribute)");

            // record structs have a compiler-generated PrintMembers method
            var printMembers = type.GetMethod(
                "PrintMembers",
                BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);

            printMembers.Should().NotBeNull(
                $"{type.Name} should be a record struct (must have PrintMembers method)");
        }
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
