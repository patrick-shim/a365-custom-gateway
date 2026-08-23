using System.Reflection;
using FluentAssertions;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Validates that each key module exposes a static DependencyInjection
/// class with extension methods for IServiceCollection registration.
/// </summary>
public class DependencyInjectionTests
{
    // ---------------------------------------------------------------
    // 1. Each key module has a DependencyInjection class
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(typeof(Gateway.Application.DependencyInjection), "Gateway.Application")]
    [InlineData(typeof(Gateway.Infrastructure.DependencyInjection), "Gateway.Infrastructure")]
    [InlineData(typeof(Gateway.Agent365.DependencyInjection), "Gateway.Agent365")]
    [InlineData(typeof(Gateway.Purview.DependencyInjection), "Gateway.Purview")]
    [InlineData(typeof(Gateway.Observability.DependencyInjection), "Gateway.Observability")]
    public void Module_Should_HaveDependencyInjectionClass(Type diType, string moduleName)
    {
        diType.Should().NotBeNull(
            $"{moduleName} must have a DependencyInjection class");

        diType.Name.Should().Be("DependencyInjection",
            $"{moduleName} DI class must be named 'DependencyInjection'");
    }

    // ---------------------------------------------------------------
    // 2. DependencyInjection classes are static
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(typeof(Gateway.Application.DependencyInjection))]
    [InlineData(typeof(Gateway.Infrastructure.DependencyInjection))]
    [InlineData(typeof(Gateway.Agent365.DependencyInjection))]
    [InlineData(typeof(Gateway.Purview.DependencyInjection))]
    [InlineData(typeof(Gateway.Observability.DependencyInjection))]
    public void DependencyInjectionClass_Should_BeStatic(Type diType)
    {
        // In C#, static classes compile to abstract + sealed
        diType.IsAbstract.Should().BeTrue(
            $"{diType.FullName} should be a static class (abstract)");
        diType.IsSealed.Should().BeTrue(
            $"{diType.FullName} should be a static class (sealed)");
    }

    // ---------------------------------------------------------------
    // 3. DependencyInjection classes have at least one static method
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(typeof(Gateway.Application.DependencyInjection))]
    [InlineData(typeof(Gateway.Infrastructure.DependencyInjection))]
    [InlineData(typeof(Gateway.Agent365.DependencyInjection))]
    [InlineData(typeof(Gateway.Purview.DependencyInjection))]
    [InlineData(typeof(Gateway.Observability.DependencyInjection))]
    public void DependencyInjectionClass_Should_HaveStaticExtensionMethods(Type diType)
    {
        var staticMethods = diType.GetMethods(
            BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly);

        staticMethods.Should().NotBeEmpty(
            $"{diType.FullName} should expose at least one public static " +
            $"extension method for service registration");
    }

    // ---------------------------------------------------------------
    // 4. Extension methods accept IServiceCollection as first parameter
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(typeof(Gateway.Application.DependencyInjection))]
    [InlineData(typeof(Gateway.Infrastructure.DependencyInjection))]
    [InlineData(typeof(Gateway.Agent365.DependencyInjection))]
    [InlineData(typeof(Gateway.Purview.DependencyInjection))]
    [InlineData(typeof(Gateway.Observability.DependencyInjection))]
    public void DependencyInjectionMethods_Should_ExtendIServiceCollection(Type diType)
    {
        var staticMethods = diType.GetMethods(
            BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly);

        foreach (var method in staticMethods)
        {
            var parameters = method.GetParameters();

            parameters.Should().NotBeEmpty(
                $"Extension method {diType.Name}.{method.Name} should have parameters");

            // Extension methods have 'this' as first parameter;
            // the compiled IL marks it with IServiceCollection type
            var firstParam = parameters[0];
            firstParam.ParameterType.FullName.Should().Contain(
                "IServiceCollection",
                $"First parameter of {diType.Name}.{method.Name} should be " +
                $"IServiceCollection (extension method pattern)");
        }
    }

    // ---------------------------------------------------------------
    // 5. Extension methods return IServiceCollection for chaining
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(typeof(Gateway.Application.DependencyInjection))]
    [InlineData(typeof(Gateway.Infrastructure.DependencyInjection))]
    [InlineData(typeof(Gateway.Agent365.DependencyInjection))]
    [InlineData(typeof(Gateway.Purview.DependencyInjection))]
    [InlineData(typeof(Gateway.Observability.DependencyInjection))]
    public void DependencyInjectionMethods_Should_ReturnIServiceCollection(Type diType)
    {
        var staticMethods = diType.GetMethods(
            BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly);

        foreach (var method in staticMethods)
        {
            method.ReturnType.FullName.Should().Contain(
                "IServiceCollection",
                $"{diType.Name}.{method.Name} should return IServiceCollection " +
                $"for fluent chaining");
        }
    }
}
