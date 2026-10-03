using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Gateway.Infrastructure.Persistence;

internal static class PostgresModelCustomizer
{
    private static readonly Regex BracketedIdentifier = new(
        @"\[(?<name>[^\]]+)\]",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex IsJsonEqualsOne = new(
        @"ISJSON\s*\(\s*(?<expr>[^)]+)\s*\)\s*=\s*1",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex DataLength = new(
        @"DATALENGTH\s*\(\s*(?<expr>[^)]+)\s*\)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex UnicodeStringLiteral = new(
        @"N'(?<text>(?:[^']|'')*)'",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex SqlServerCollate = new(
        @"\s+COLLATE\s+[A-Za-z0-9_]+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex LikeNotCharacterClass = new(
        @"NOT\s+LIKE\s+N?'%\[\^(?<class>[^\]]+)\]%'",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly HashSet<string> SqlKeywords = new(StringComparer.OrdinalIgnoreCase)
    {
        "AND", "OR", "NOT", "NULL", "TRUE", "FALSE", "IN", "IS", "BETWEEN", "LIKE",
        "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "AS"
    };

    public static void Apply(ModelBuilder modelBuilder)
    {
        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            foreach (var property in entityType.GetProperties())
            {
                var columnType = property.GetColumnType();
                if (!string.IsNullOrWhiteSpace(columnType))
                {
                    var mapped = MapSqlServerColumnType(columnType);
                    if (!string.Equals(mapped, columnType, StringComparison.OrdinalIgnoreCase))
                        property.SetColumnType(mapped);
                }

                var defaultSql = property.GetDefaultValueSql();
                if (!string.IsNullOrWhiteSpace(defaultSql))
                {
                    var mappedDefault = MapSqlServerDefaultSql(defaultSql);
                    if (!string.Equals(mappedDefault, defaultSql, StringComparison.Ordinal))
                        property.SetDefaultValueSql(mappedDefault);
                }
            }

            var columnNames = entityType.GetProperties()
                .Select(property => property.GetColumnName())
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            var booleanColumns = entityType.GetProperties()
                .Where(property => property.ClrType == typeof(bool) || property.ClrType == typeof(bool?))
                .Select(property => property.GetColumnName())
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Distinct(StringComparer.Ordinal)
                .ToArray();

            foreach (var check in entityType.GetCheckConstraints().ToList())
            {
                if (string.IsNullOrWhiteSpace(check.Name) || string.IsNullOrWhiteSpace(check.Sql))
                    continue;

                entityType.RemoveCheckConstraint(check.Name);
                entityType.AddCheckConstraint(
                    check.Name,
                    ToPostgresCheckSql(check.Sql, columnNames, booleanColumns));
            }

            foreach (var index in entityType.GetIndexes())
            {
                var filter = index.GetFilter();
                if (string.IsNullOrWhiteSpace(filter))
                    continue;

                index.SetFilter(ToPostgresCheckSql(filter, columnNames, booleanColumns));
            }

            var rowVersion = entityType.FindProperty("RowVersion");
            if (rowVersion is null)
                continue;

            rowVersion.ValueGenerated = ValueGenerated.Never;
            rowVersion.IsConcurrencyToken = true;
            rowVersion.SetColumnType("bytea");
            rowVersion.SetDefaultValueSql(null);
            rowVersion.SetBeforeSaveBehavior(PropertySaveBehavior.Save);
            rowVersion.SetAfterSaveBehavior(PropertySaveBehavior.Save);
        }
    }

    internal static string MapSqlServerColumnType(string columnType)
    {
        var normalized = columnType.Trim();
        if (normalized.Equals("nvarchar(max)", StringComparison.OrdinalIgnoreCase) ||
            normalized.Equals("varchar(max)", StringComparison.OrdinalIgnoreCase) ||
            normalized.Equals("ntext", StringComparison.OrdinalIgnoreCase) ||
            normalized.Equals("text", StringComparison.OrdinalIgnoreCase))
        {
            return "text";
        }

        if (normalized.StartsWith("nvarchar(", StringComparison.OrdinalIgnoreCase) ||
            normalized.StartsWith("varchar(", StringComparison.OrdinalIgnoreCase))
        {
            var open = normalized.IndexOf('(');
            var close = normalized.IndexOf(')');
            if (open > 0 && close > open)
                return $"character varying{normalized[open..(close + 1)]}";
        }

        if (normalized.Equals("uniqueidentifier", StringComparison.OrdinalIgnoreCase))
            return "uuid";
        if (normalized.StartsWith("datetime2", StringComparison.OrdinalIgnoreCase))
            return "timestamp with time zone";
        if (normalized.Equals("bit", StringComparison.OrdinalIgnoreCase))
            return "boolean";
        if (normalized.Equals("varbinary(max)", StringComparison.OrdinalIgnoreCase) ||
            normalized.Equals("rowversion", StringComparison.OrdinalIgnoreCase) ||
            normalized.Equals("timestamp", StringComparison.OrdinalIgnoreCase))
        {
            return "bytea";
        }

        return normalized;
    }

    internal static string MapSqlServerDefaultSql(string defaultSql)
    {
        var sql = defaultSql.Trim();
        sql = Regex.Replace(sql, @"\bNEWID\s*\(\s*\)", "gen_random_uuid()", RegexOptions.IgnoreCase);
        sql = Regex.Replace(sql, @"\bNEWSEQUENTIALID\s*\(\s*\)", "gen_random_uuid()", RegexOptions.IgnoreCase);
        sql = Regex.Replace(sql, @"\bSYSUTCDATETIME\s*\(\s*\)", "(now() AT TIME ZONE 'utc')", RegexOptions.IgnoreCase);
        sql = Regex.Replace(sql, @"\bGETUTCDATE\s*\(\s*\)", "(now() AT TIME ZONE 'utc')", RegexOptions.IgnoreCase);
        sql = Regex.Replace(sql, @"\bGETDATE\s*\(\s*\)", "now()", RegexOptions.IgnoreCase);
        return sql;
    }

    internal static string ToPostgresCheckSql(
        string sqlServerSql,
        IReadOnlyCollection<string> columnNames,
        IReadOnlyCollection<string> booleanColumns)
    {
        var sql = sqlServerSql;

        // Convert SQL Server LIKE character-class negations before touching brackets.
        sql = LikeNotCharacterClass.Replace(
            sql,
            match => $"!~ '[^{match.Groups["class"].Value}]'");

        sql = BracketedIdentifier.Replace(sql, "\"${name}\"");
        sql = UnicodeStringLiteral.Replace(sql, "'${text}'");
        sql = IsJsonEqualsOne.Replace(sql, "(${expr})::jsonb IS NOT NULL");
        sql = DataLength.Replace(sql, "octet_length(${expr})");
        sql = SqlServerCollate.Replace(sql, " COLLATE \"C\"");
        sql = Regex.Replace(sql, @"\bLEFT\s*\(", "left(", RegexOptions.IgnoreCase);
        sql = Regex.Replace(sql, @"\bLTRIM\s*\(", "ltrim(", RegexOptions.IgnoreCase);

        foreach (var column in booleanColumns.OrderByDescending(name => name.Length))
        {
            sql = Regex.Replace(
                sql,
                $@"(""{Regex.Escape(column)}""|\b{Regex.Escape(column)}\b)\s*=\s*0\b",
                $"\"{column}\" = FALSE",
                RegexOptions.IgnoreCase);
            sql = Regex.Replace(
                sql,
                $@"(""{Regex.Escape(column)}""|\b{Regex.Escape(column)}\b)\s*=\s*1\b",
                $"\"{column}\" = TRUE",
                RegexOptions.IgnoreCase);
        }

        foreach (var column in columnNames.OrderByDescending(name => name.Length))
            sql = QuoteBareIdentifier(sql, column);

        return sql;
    }

    private static string QuoteBareIdentifier(string sql, string identifier)
    {
        if (SqlKeywords.Contains(identifier))
            return sql;

        var quoted = $"\"{identifier}\"";
        var result = new System.Text.StringBuilder(sql.Length + 8);
        var index = 0;
        while (index < sql.Length)
        {
            var match = sql.IndexOf(identifier, index, StringComparison.Ordinal);
            if (match < 0)
            {
                result.Append(sql, index, sql.Length - index);
                break;
            }

            result.Append(sql, index, match - index);
            var alreadyQuoted =
                match > 0 &&
                sql[match - 1] == '"' &&
                match + identifier.Length < sql.Length &&
                sql[match + identifier.Length] == '"';
            var boundaryLeft = match == 0 || !IsIdentifierChar(sql[match - 1]);
            var boundaryRight =
                match + identifier.Length == sql.Length ||
                !IsIdentifierChar(sql[match + identifier.Length]);

            if (!alreadyQuoted && boundaryLeft && boundaryRight)
                result.Append(quoted);
            else
                result.Append(identifier);

            index = match + identifier.Length;
        }

        return result.ToString();
    }

    private static bool IsIdentifierChar(char value) =>
        char.IsLetterOrDigit(value) || value is '_' or '"';
}
