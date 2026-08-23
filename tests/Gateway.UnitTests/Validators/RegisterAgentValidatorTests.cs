using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Validators;
using Gateway.Contracts.Dtos;

namespace Gateway.UnitTests.Validators;

public class RegisterAgentValidatorTests
{
    private readonly RegisterAgentValidator _validator = new();

    private static RegisterAgentCommand CreateValidCommand() =>
        new(
            ExternalAgentId: "agent-001",
            Name: "Test Agent",
            Description: "A test agent for unit testing",
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            CallerObjectId: "caller-oid-001");

    [Fact]
    public void Validate_Should_Pass_When_CommandIsValid()
    {
        var command = CreateValidCommand();

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_DescriptionIsNull()
    {
        var command = CreateValidCommand() with { Description = null };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_FeaturesAreProvided()
    {
        var command = CreateValidCommand() with
        {
            Features = new AgentFeaturesDto("GatewayOnly", true, "AuditOnly")
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_ExternalAgentIdIsEmpty()
    {
        var command = CreateValidCommand() with { ExternalAgentId = "" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ExternalAgentId");
    }

    [Fact]
    public void Validate_Should_Fail_When_ExternalAgentIdExceeds128Chars()
    {
        var command = CreateValidCommand() with { ExternalAgentId = new string('a', 129) };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ExternalAgentId");
    }

    [Fact]
    public void Validate_Should_Fail_When_ExternalAgentIdContainsInvalidChars()
    {
        var command = CreateValidCommand() with { ExternalAgentId = "agent@test" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ExternalAgentId");
    }

    [Fact]
    public void Validate_Should_Fail_When_NameIsEmpty()
    {
        var command = CreateValidCommand() with { Name = "" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Name");
    }

    [Fact]
    public void Validate_Should_Fail_When_NameExceeds256Chars()
    {
        var command = CreateValidCommand() with { Name = new string('x', 257) };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Name");
    }

    [Fact]
    public void Validate_Should_Fail_When_DescriptionExceeds2000Chars()
    {
        var command = CreateValidCommand() with { Description = new string('x', 2001) };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Description");
    }

    [Fact]
    public void Validate_Should_Fail_When_OwnerObjectIdIsEmpty()
    {
        var command = CreateValidCommand() with { OwnerObjectId = "" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "OwnerObjectId");
    }

    [Fact]
    public void Validate_Should_Fail_When_EnvironmentIsInvalid()
    {
        var command = CreateValidCommand() with { Environment = "InvalidEnv" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Environment");
    }

    [Fact]
    public void Validate_Should_Fail_When_EnvironmentIsEmpty()
    {
        var command = CreateValidCommand() with { Environment = "" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Environment");
    }

    [Theory]
    [InlineData("Development")]
    [InlineData("Test")]
    [InlineData("Production")]
    public void Validate_Should_Pass_When_EnvironmentIsValid(string environment)
    {
        var command = CreateValidCommand() with { Environment = environment };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }
}
