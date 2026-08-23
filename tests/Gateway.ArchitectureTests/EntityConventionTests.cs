using System.Reflection;
using FluentAssertions;
using NetArchTest.Rules;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Validates EF Core entity conventions. Every entity must have an Id
/// property, must be a class, and must have a corresponding
/// IEntityTypeConfiguration in the Infrastructure layer.
/// </summary>
public class EntityConventionTests
{
    private static readonly Assembly DomainAssembly =
        typeof(Gateway.Domain.Entities.AgentRegistration).Assembly;

    private static readonly Assembly InfrastructureAssembly =
        typeof(Gateway.Infrastructure.DependencyInjection).Assembly;

    // ---------------------------------------------------------------
    // 1. All entities have an Id property
    // ---------------------------------------------------------------

    [Fact]
    public void AllEntities_Should_HaveIdProperty()
    {
        var entityTypes = Types.InAssembly(DomainAssembly)
            .That()
            .ResideInNamespace("Gateway.Domain.Entities")
            .GetTypes();

        entityTypes.Should().NotBeEmpty(
            "there should be entity types in Domain.Entities");

        foreach (var type in entityTypes)
        {
            var idProperty = type.GetProperty("Id",
                BindingFlags.Public | BindingFlags.Instance);

            idProperty.Should().NotBeNull(
                $"Entity {type.Name} must have a public Id property");
        }
    }

    // ---------------------------------------------------------------
    // 2. All entities should be classes, not records or structs
    // ---------------------------------------------------------------

    [Fact]
    public void AllEntities_Should_BeClasses()
    {
        var result = Types.InAssembly(DomainAssembly)
            .That()
            .ResideInNamespace("Gateway.Domain.Entities")
            .Should()
            .BeClasses()
            .GetResult();

        result.IsSuccessful.Should().BeTrue(
            $"All types in Domain.Entities must be classes. " +
            $"Violations: {FormatFailingTypes(result)}");
    }

    // ---------------------------------------------------------------
    // 3. Entity configurations exist for each entity
    // ---------------------------------------------------------------

    [Fact]
    public void AllEntities_Should_HaveCorrespondingEntityConfiguration()
    {
        var entityTypes = Types.InAssembly(DomainAssembly)
            .That()
            .ResideInNamespace("Gateway.Domain.Entities")
            .GetTypes();

        var configurationTypes = Types.InAssembly(InfrastructureAssembly)
            .That()
            .ResideInNamespace("Gateway.Infrastructure.Persistence.Configurations")
            .GetTypes();

        entityTypes.Should().NotBeEmpty(
            "there should be entity types in Domain.Entities");

        configurationTypes.Should().NotBeEmpty(
            "there should be configuration types in Infrastructure.Persistence.Configurations");

        var configTypeNames = configurationTypes
            .Select(t => t.Name)
            .ToHashSet();

        foreach (var entity in entityTypes)
        {
            var expectedConfigName = $"{entity.Name}Configuration";

            configTypeNames.Should().Contain(
                expectedConfigName,
                $"Entity '{entity.Name}' must have a corresponding EF Core " +
                $"configuration class named '{expectedConfigName}' in " +
                $"Gateway.Infrastructure.Persistence.Configurations");
        }
    }

    // ---------------------------------------------------------------
    // 4. Entity Id properties are of type Guid
    // ---------------------------------------------------------------

    [Fact]
    public void AllEntities_Should_HaveGuidIdProperty()
    {
        var entityTypes = Types.InAssembly(DomainAssembly)
            .That()
            .ResideInNamespace("Gateway.Domain.Entities")
            .GetTypes();

        entityTypes.Should().NotBeEmpty(
            "there should be entity types in Domain.Entities");

        foreach (var type in entityTypes)
        {
            var idProperty = type.GetProperty("Id",
                BindingFlags.Public | BindingFlags.Instance);

            idProperty.Should().NotBeNull(
                $"Entity {type.Name} must have a public Id property");

            idProperty!.PropertyType.Should().Be(typeof(Guid),
                $"Entity {type.Name}.Id should be of type Guid");
        }
    }

    // ---------------------------------------------------------------
    // 5. Entities are not sealed (allow EF Core proxies/navigation)
    // ---------------------------------------------------------------

    [Fact]
    public void AllEntities_Should_NotBeSealed()
    {
        var entityTypes = Types.InAssembly(DomainAssembly)
            .That()
            .ResideInNamespace("Gateway.Domain.Entities")
            .GetTypes();

        entityTypes.Should().NotBeEmpty(
            "there should be entity types in Domain.Entities");

        foreach (var type in entityTypes)
        {
            type.IsSealed.Should().BeFalse(
                $"Entity {type.Name} should not be sealed to support " +
                $"EF Core lazy loading proxies and navigation property initialization");
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
