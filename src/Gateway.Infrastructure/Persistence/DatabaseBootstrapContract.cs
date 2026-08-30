namespace Gateway.Infrastructure.Persistence;

/// <summary>
/// Pure, testable guards for the clean-database bootstrap boundary.
/// Provider reads are projected into a bounded schema snapshot before this
/// contract is evaluated; no provider absence is inferred from exceptions.
/// </summary>
public static class DatabaseBootstrapContract
{
    public static void AssertEmptyUserTableCount(int userTableCount)
    {
        if (userTableCount != 0)
        {
            throw new InvalidOperationException(
                "Clean bootstrap requires exactly zero user tables before initialization; an existing database is never adopted.");
        }
    }

    public static void AssertExactCurrentSchema(
        DatabaseSchemaContractSnapshot expected,
        DatabaseSchemaContractSnapshot actual)
    {
        ArgumentNullException.ThrowIfNull(expected);
        ArgumentNullException.ThrowIfNull(actual);

        if (!ExactSet(expected.Tables, actual.Tables) ||
            !ExactSet(expected.Columns, actual.Columns) ||
            !ExactSet(expected.Indexes, actual.Indexes) ||
            actual.ProgrammableObjectCount != 0)
        {
            throw new InvalidOperationException(
                "GatewayDb does not exactly match the reviewed current EF table, column, and index contract, or contains an unreviewed programmable object.");
        }
    }

    public static void AssertRuntimePrincipalAuthority(
        IReadOnlyCollection<string> observedRoles,
        IReadOnlyCollection<string> expectedRoles,
        IReadOnlyCollection<string> observedDirectPermissions,
        IReadOnlyCollection<string> expectedDirectPermissions,
        int ownedSchemaCount,
        int ownedPrincipalCount,
        bool requireCompleteRoleSet)
    {
        var observed = observedRoles.Order(StringComparer.Ordinal).ToArray();
        var expected = expectedRoles.Order(StringComparer.Ordinal).ToArray();
        if (observed.Length != observed.Distinct(StringComparer.Ordinal).Count() ||
            observed.Except(expected, StringComparer.Ordinal).Any() ||
            (requireCompleteRoleSet && !observed.SequenceEqual(expected, StringComparer.Ordinal)) ||
            !ExactSet(expectedDirectPermissions, observedDirectPermissions) ||
            ownedSchemaCount != 0 || ownedPrincipalCount != 0)
        {
            throw new InvalidOperationException(
                "A Gateway runtime database principal has an unreviewed role, direct permission, or ownership boundary.");
        }
    }

    private static bool ExactSet(
        IReadOnlyCollection<string> expected,
        IReadOnlyCollection<string> actual)
    {
        var expectedValues = expected.Order(StringComparer.Ordinal).ToArray();
        var actualValues = actual.Order(StringComparer.Ordinal).ToArray();
        return expectedValues.Length == expectedValues.Distinct(StringComparer.Ordinal).Count() &&
               actualValues.Length == actualValues.Distinct(StringComparer.Ordinal).Count() &&
               expectedValues.SequenceEqual(actualValues, StringComparer.Ordinal);
    }
}

public sealed record DatabaseSchemaContractSnapshot(
    IReadOnlyCollection<string> Tables,
    IReadOnlyCollection<string> Columns,
    IReadOnlyCollection<string> Indexes,
    int ProgrammableObjectCount);
