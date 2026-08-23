using System.Text.RegularExpressions;

namespace Gateway.Domain.ValueObjects;

public readonly partial record struct ExternalAgentId
{
    private const int MinLength = 3;
    private const int MaxLength = 128;
    private const string Pattern = @"^[a-zA-Z0-9][a-zA-Z0-9._-]*$";

    public string Value { get; }

    public ExternalAgentId(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);

        if (value.Length < MinLength || value.Length > MaxLength)
            throw new ArgumentException(
                $"ExternalAgentId must be between {MinLength} and {MaxLength} characters.",
                nameof(value));

        if (!ValidationRegex().IsMatch(value))
            throw new ArgumentException(
                $"ExternalAgentId must match pattern {Pattern}.",
                nameof(value));

        Value = value;
    }

    public override string ToString() => Value;

    [GeneratedRegex(Pattern)]
    private static partial Regex ValidationRegex();
}
