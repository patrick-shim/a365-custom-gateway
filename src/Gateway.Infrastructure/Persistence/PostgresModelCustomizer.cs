using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Gateway.Infrastructure.Persistence;

internal static class PostgresModelCustomizer
{
    public static void Apply(ModelBuilder modelBuilder)
    {
        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
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
}
