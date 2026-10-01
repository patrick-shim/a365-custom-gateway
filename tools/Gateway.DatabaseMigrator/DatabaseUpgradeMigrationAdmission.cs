namespace Gateway.DatabaseMigrator;

public static class DatabaseUpgradeMigrationAdmission
{
    public static IReadOnlyList<string> RequiredCurrentScripts { get; } = Array.AsReadOnly<string>(
    [
        "20260910_capability_preparation_receipts.sql",
        "20260910_purview_configuration_intent.sql",
        "20260910_purview_runtime_tests.sql",
        "20260911_prompt_receipt_protection_context.sql"
    ]);

    public static void AssertRequiredScripts(IEnumerable<string> scriptNames)
    {
        var selected = scriptNames.ToArray();
        if (!selected.Where(name => RequiredCurrentScripts.Contains(name, StringComparer.Ordinal))
                .SequenceEqual(RequiredCurrentScripts, StringComparer.Ordinal))
            throw new ArgumentException(
                "UpgradeSqlAdmission: every required current migration must be present exactly once in reviewed order.");
    }
}
