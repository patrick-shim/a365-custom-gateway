using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Validators;
using Gateway.Contracts.Dtos;

internal static class RegistrationValidationTests
{
    public static void Run()
    {
        var validator = new RegisterAgentValidator();
        var blueprint = new AgentBlueprintSelectionDto("UseExisting", Guid.NewGuid().ToString("D"), null);

        var invalid = validator.Validate(new RegisterAgentCommand(
            "ab", "Agent", null, Guid.NewGuid().ToString("D"), "Development",
            null, Guid.NewGuid().ToString("D"), blueprint));
        if (invalid.IsValid || !invalid.Errors.Any(error => error.PropertyName == "ExternalAgentId"))
            throw new Exception("A two-character external agent ID must fail application validation.");

        var valid = validator.Validate(new RegisterAgentCommand(
            "abc", "Agent", null, Guid.NewGuid().ToString("D"), "Development",
            null, Guid.NewGuid().ToString("D"), blueprint));
        if (!valid.IsValid)
            throw new Exception("A valid three-character external agent ID was rejected.");

        Console.WriteLine("Registration external agent ID boundary validation passed.");
    }
}
