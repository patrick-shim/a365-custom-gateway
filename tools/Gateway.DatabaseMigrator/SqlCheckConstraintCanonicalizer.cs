using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.SqlServer.TransactSql.ScriptDom;

namespace Gateway.DatabaseMigrator;

public static class SqlCheckConstraintCanonicalizer
{
    public static string Normalize(string expression)
    {
        if (string.IsNullOrWhiteSpace(expression) || expression.Length > 16384)
            throw new InvalidOperationException("The CHECK expression is empty or exceeds its reviewed bound.");
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        var parsed = parser.ParseBooleanExpression(new StringReader(expression), out var errors, 0, 1, 1);
        if (errors.Count != 0 || parsed is null ||
            parsed.ScriptTokenStream.Skip(parsed.LastTokenIndex + 1)
                .Any(token => token.TokenType is not (TSqlTokenType.WhiteSpace or TSqlTokenType.EndOfFile)))
            throw new InvalidOperationException("The CHECK expression is not one complete supported SQL predicate.");
        var canonical = JsonSerializer.Serialize(Boolean(parsed));
        return "tsql-check-v1:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    }

    private sealed record Form(string Kind, IReadOnlyList<Form> Children, string? Value = null);

    private static Form Boolean(BooleanExpression expression) => expression switch
    {
        BooleanParenthesisExpression group => Boolean(group.Expression),
        BooleanBinaryExpression binary => Combine(binary.BinaryExpressionType.ToString(),
            [Boolean(binary.FirstExpression), Boolean(binary.SecondExpression)]),
        BooleanNotExpression not => new("not", [Boolean(not.Expression)]),
        BooleanComparisonExpression comparison => new(
            comparison.ComparisonType == BooleanComparisonType.NotEqualToExclamation
                ? BooleanComparisonType.NotEqualToBrackets.ToString() : comparison.ComparisonType.ToString(),
            [Scalar(comparison.FirstExpression), Scalar(comparison.SecondExpression)]),
        BooleanIsNullExpression isNull => new(isNull.IsNot ? "is-not-null" : "is-null", [Scalar(isNull.Expression)]),
        InPredicate { Subquery: null, Values.Count: > 0 } inside => NegateIf(inside.NotDefined,
            Combine(BooleanBinaryExpressionType.Or.ToString(), inside.Values.Select(value =>
                new Form(BooleanComparisonType.Equals.ToString(), [Scalar(inside.Expression), Scalar(value)])))),
        LikePredicate like => NegateIf(like.NotDefined, new("like",
            like.EscapeExpression is null
                ? [Scalar(like.FirstExpression), Scalar(like.SecondExpression)]
                : [Scalar(like.FirstExpression), Scalar(like.SecondExpression), Scalar(like.EscapeExpression)],
            like.OdbcEscape.ToString())),
        _ => throw new InvalidOperationException("The CHECK predicate requires an explicit canonicalization contract.")
    };

    private static Form NegateIf(bool negate, Form expression) => negate ? new("not", [expression]) : expression;

    private static Form Combine(string kind, IEnumerable<Form> children)
    {
        // SQL Server flattens associative Boolean groups and expands IN in reversed order.
        // Keep AND/OR as distinct tree nodes; never discard precedence or literal content.
        var flattened = children.SelectMany(child => child.Kind == kind ? child.Children : [child])
            .OrderBy(child => JsonSerializer.Serialize(child), StringComparer.Ordinal).ToArray();
        return flattened.Length == 1 ? flattened[0] : new(kind, flattened);
    }

    private static Form Scalar(ScalarExpression expression)
    {
        var primary = expression as PrimaryExpression;
        var collation = primary?.Collation;
        if (primary is not null) primary.Collation = null;
        Form result;
        try
        {
            result = expression switch
            {
                ParenthesisExpression group => Scalar(group.Expression),
                FunctionCall function => Function(function),
                LeftFunctionCall left => new("left", left.Parameters.Select(Scalar).ToArray()),
                RightFunctionCall right => new("right", right.Parameters.Select(Scalar).ToArray()),
                _ => new("scalar", [], Tokens(expression))
            };
        }
        finally
        {
            if (primary is not null) primary.Collation = collation;
        }
        return collation is null ? result : new("collate", [result], collation.Value.ToLowerInvariant());
    }

    private static Form Function(FunctionCall function)
    {
        var parameters = function.Parameters.ToArray();
        function.Parameters.Clear();
        foreach (var parameter in parameters) function.Parameters.Add(new NullLiteral());
        string shape;
        try
        {
            // Some modifiers (for example TRIM LEADING) are emitted only with arguments.
            // Placeholders retain the complete shape while arguments are compared separately.
            shape = Tokens(function);
        }
        finally
        {
            function.Parameters.Clear();
            foreach (var parameter in parameters) function.Parameters.Add(parameter);
        }
        return new("function", parameters.Select(Scalar).ToArray(), shape);
    }

    private static string Tokens(TSqlFragment expression)
    {
        new Sql160ScriptGenerator().GenerateScript(expression, out var script);
        var tokens = new TSql160Parser(initialQuotedIdentifiers: true)
            .GetTokenStream(new StringReader(script), out var errors);
        if (errors.Count != 0)
            throw new InvalidOperationException("The CHECK scalar could not be canonicalized.");
        return JsonSerializer.Serialize(tokens
            .Where(token => token.TokenType is not (TSqlTokenType.WhiteSpace or TSqlTokenType.EndOfFile))
            .Select(token => token.TokenType switch
            {
                TSqlTokenType.Identifier => new[] { "identifier", token.Text.ToLowerInvariant() },
                TSqlTokenType.QuotedIdentifier => new[] { "identifier", DecodeIdentifier(token.Text).ToLowerInvariant() },
                TSqlTokenType.AsciiStringLiteral or TSqlTokenType.UnicodeStringLiteral =>
                    new[] { token.TokenType.ToString(), token.Text },
                _ => new[] { token.TokenType.ToString(), token.Text.ToLowerInvariant() }
            }).ToArray());
    }

    private static string DecodeIdentifier(string value) => value[0] switch
    {
        '[' => value[1..^1].Replace("]]", "]", StringComparison.Ordinal),
        '"' => value[1..^1].Replace("\"\"", "\"", StringComparison.Ordinal),
        _ => throw new InvalidOperationException("The CHECK identifier quoting is unsupported.")
    };
}
