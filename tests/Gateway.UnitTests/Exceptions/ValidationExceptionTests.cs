using FluentAssertions;
using Gateway.Application.Exceptions;

namespace Gateway.UnitTests.Exceptions;

public class ValidationExceptionTests
{
    [Fact]
    public void Constructor_Should_PopulateErrorsDictionary()
    {
        var errors = new Dictionary<string, string[]>
        {
            ["Name"] = ["Name is required."],
            ["ExternalAgentId"] = ["ExternalAgentId must not be empty.", "ExternalAgentId must match pattern."]
        };

        var exception = new ValidationException(errors);

        exception.Errors.Should().HaveCount(2);
        exception.Errors["Name"].Should().ContainSingle("Name is required.");
        exception.Errors["ExternalAgentId"].Should().HaveCount(2);
    }

    [Fact]
    public void Constructor_Should_SetMessage()
    {
        var errors = new Dictionary<string, string[]>
        {
            ["Field"] = ["Error"]
        };

        var exception = new ValidationException(errors);

        exception.Message.Should().Contain("validation");
    }

    [Fact]
    public void Constructor_Should_AcceptEmptyErrorsDictionary()
    {
        var errors = new Dictionary<string, string[]>();

        var exception = new ValidationException(errors);

        exception.Errors.Should().BeEmpty();
    }

    [Fact]
    public void Errors_Should_ContainAllProvidedEntries()
    {
        var errors = new Dictionary<string, string[]>
        {
            ["Field1"] = ["Error1"],
            ["Field2"] = ["Error2a", "Error2b"],
            ["Field3"] = ["Error3"]
        };

        var exception = new ValidationException(errors);

        exception.Errors.Should().ContainKey("Field1");
        exception.Errors.Should().ContainKey("Field2");
        exception.Errors.Should().ContainKey("Field3");
        exception.Errors["Field2"].Should().Contain("Error2a");
        exception.Errors["Field2"].Should().Contain("Error2b");
    }
}

public class NotFoundExceptionTests
{
    [Fact]
    public void Constructor_Should_SetEntityAndKey()
    {
        var exception = new NotFoundException("AgentRegistration", Guid.Empty);

        exception.Entity.Should().Be("AgentRegistration");
        exception.Key.Should().NotBeNullOrEmpty();
        exception.Message.Should().Contain("AgentRegistration");
    }

    [Fact]
    public void Constructor_Should_SetMessage_With_StringKey()
    {
        var exception = new NotFoundException("AgentRegistration", "agent-001");

        exception.Entity.Should().Be("AgentRegistration");
        exception.Key.Should().Be("agent-001");
        exception.Message.Should().Contain("agent-001");
    }
}

public class ConflictExceptionTests
{
    [Fact]
    public void Constructor_Should_SetMessageAndErrorCode()
    {
        var exception = new ConflictException("Conflict occurred", "DUPLICATE_EXTERNAL_AGENT_ID");

        exception.Message.Should().Be("Conflict occurred");
        exception.ErrorCode.Should().Be("DUPLICATE_EXTERNAL_AGENT_ID");
    }

    [Fact]
    public void Constructor_Should_AllowNullErrorCode()
    {
        var exception = new ConflictException("Conflict occurred");

        exception.ErrorCode.Should().BeNull();
    }
}

public class InvalidStateTransitionExceptionTests
{
    [Fact]
    public void Constructor_Should_SetCurrentStateAndAttemptedAction()
    {
        var exception = new InvalidStateTransitionException("Draft", "Enable");

        exception.CurrentState.Should().Be("Draft");
        exception.AttemptedAction.Should().Be("Enable");
        exception.Message.Should().Contain("Draft");
        exception.Message.Should().Contain("Enable");
    }
}

public class DomainExceptionTests
{
    [Fact]
    public void Constructor_Should_SetMessageAndErrorCode()
    {
        var exception = new DomainException("Identity mismatch", "AGENT_IDENTITY_MISMATCH");

        exception.Message.Should().Be("Identity mismatch");
        exception.ErrorCode.Should().Be("AGENT_IDENTITY_MISMATCH");
    }
}
