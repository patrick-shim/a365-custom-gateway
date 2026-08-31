namespace Gateway.Infrastructure.Persistence;

/// <summary>
/// Pure guard for the exact runtime database-principal authority accepted by the
/// database migrator. Provider reads are projected before this contract is
/// evaluated; no provider absence is inferred from exceptions.
/// </summary>
public static class DatabaseBootstrapContract
{
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
