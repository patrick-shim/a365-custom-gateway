using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;

namespace Gateway.Infrastructure.Persistence;

/// <summary>
/// Reads a canonical, content-free projection of every reviewed GatewayDb
/// relational surface. The bootstrap migrator records this fingerprint only
/// after its EF-model comparison succeeds; runtime attestation recomputes the
/// same fingerprint over the current private database.
/// </summary>
public static class DatabaseSchemaFingerprintReader
{
    public const int ContractVersion = 1;

    private static readonly string[] ContractQueries =
    [
        // Tables and their storage/runtime characteristics.
        """
        SELECT COALESCE((
            SELECT schemas.name AS [schema], tables.name,
                   tables.temporal_type, tables.is_memory_optimized,
                   tables.durability_desc, tables.lob_data_space_id,
                   tables.filestream_data_space_id, tables.is_external,
                   tables.is_filetable, tables.is_node, tables.is_edge,
                   tables.ledger_type, tables.lock_escalation_desc,
                   tables.lock_on_bulk_load, tables.large_value_types_out_of_row,
                   tables.is_replicated, tables.is_merge_published,
                   tables.is_sync_tran_subscribed, tables.is_tracked_by_cdc,
                   tables.is_remote_data_archive_enabled, tables.uses_ansi_nulls,
                   tables.has_replication_filter
            FROM sys.tables AS tables
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """,
        // Columns, generated/default/computed values, encryption, and masking.
        """
        SELECT COALESCE((
            SELECT schemas.name AS [schema], tables.name AS [table], columns.name,
                   types.name AS type_name, columns.max_length, columns.precision,
                   columns.scale, columns.is_nullable, columns.collation_name,
                   columns.is_identity, identity_columns.seed_value,
                   identity_columns.increment_value,
                   identity_columns.is_not_for_replication,
                   columns.is_rowguidcol, columns.generated_always_type,
                   columns.is_sparse, columns.is_column_set,
                   columns.is_filestream, columns.is_hidden,
                   columns.encryption_type, columns.encryption_algorithm_name,
                   columns.column_encryption_key_id,
                   COALESCE(masked_columns.is_masked, 0) AS is_masked,
                   masked_columns.masking_function,
                   columns.is_xml_document,
                   columns.xml_collection_id, columns.rule_object_id,
                   default_constraints.definition AS default_definition,
                   computed_columns.definition AS computed_definition,
                   computed_columns.is_persisted
            FROM sys.tables AS tables
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.columns AS columns ON columns.object_id = tables.object_id
            INNER JOIN sys.types AS types
              ON types.user_type_id = columns.user_type_id
             AND types.system_type_id = columns.system_type_id
            LEFT JOIN sys.identity_columns AS identity_columns
              ON identity_columns.object_id = columns.object_id
             AND identity_columns.column_id = columns.column_id
            LEFT JOIN sys.default_constraints AS default_constraints
              ON default_constraints.object_id = columns.default_object_id
            LEFT JOIN sys.computed_columns AS computed_columns
              ON computed_columns.object_id = columns.object_id
             AND computed_columns.column_id = columns.column_id
            LEFT JOIN sys.masked_columns AS masked_columns
              ON masked_columns.object_id = columns.object_id
             AND masked_columns.column_id = columns.column_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, columns.column_id
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """,
        // Primary/unique constraints and their backing indexes/columns.
        """
        SELECT COALESCE((
            SELECT schemas.name AS [schema], tables.name AS [table],
                   constraints.name, constraints.type,
                   indexes.type_desc, data_spaces.name AS data_space,
                   indexes.is_disabled, indexes.is_hypothetical,
                   indexes.fill_factor, indexes.is_padded,
                   indexes.ignore_dup_key, indexes.allow_row_locks,
                   indexes.allow_page_locks, indexes.optimize_for_sequential_key,
                   COALESCE(stats.no_recompute, 0) AS statistics_no_recompute,
                   index_columns.key_ordinal, index_columns.is_descending_key,
                   columns.name AS column_name
            FROM sys.key_constraints AS constraints
            INNER JOIN sys.tables AS tables ON tables.object_id = constraints.parent_object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.indexes AS indexes
              ON indexes.object_id = constraints.parent_object_id
             AND indexes.index_id = constraints.unique_index_id
            INNER JOIN sys.data_spaces AS data_spaces ON data_spaces.data_space_id = indexes.data_space_id
            LEFT JOIN sys.stats AS stats
              ON stats.object_id = indexes.object_id AND stats.stats_id = indexes.index_id
            INNER JOIN sys.index_columns AS index_columns
              ON index_columns.object_id = indexes.object_id
             AND index_columns.index_id = indexes.index_id
             AND index_columns.key_ordinal > 0
            INNER JOIN sys.columns AS columns
              ON columns.object_id = index_columns.object_id
             AND columns.column_id = index_columns.column_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, constraints.name, index_columns.key_ordinal
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """,
        // Foreign keys, both column orders, trust/disable state, and both actions.
        """
        SELECT COALESCE((
            SELECT parent_schemas.name AS parent_schema,
                   parent_tables.name AS parent_table, foreign_keys.name,
                   foreign_key_columns.constraint_column_id,
                   parent_columns.name AS parent_column,
                   referenced_schemas.name AS referenced_schema,
                   referenced_tables.name AS referenced_table,
                   referenced_columns.name AS referenced_column,
                   foreign_keys.delete_referential_action_desc,
                   foreign_keys.update_referential_action_desc,
                   foreign_keys.is_disabled, foreign_keys.is_not_trusted
            FROM sys.foreign_keys AS foreign_keys
            INNER JOIN sys.tables AS parent_tables ON parent_tables.object_id = foreign_keys.parent_object_id
            INNER JOIN sys.schemas AS parent_schemas ON parent_schemas.schema_id = parent_tables.schema_id
            INNER JOIN sys.tables AS referenced_tables ON referenced_tables.object_id = foreign_keys.referenced_object_id
            INNER JOIN sys.schemas AS referenced_schemas ON referenced_schemas.schema_id = referenced_tables.schema_id
            INNER JOIN sys.foreign_key_columns AS foreign_key_columns
              ON foreign_key_columns.constraint_object_id = foreign_keys.object_id
            INNER JOIN sys.columns AS parent_columns
              ON parent_columns.object_id = foreign_key_columns.parent_object_id
             AND parent_columns.column_id = foreign_key_columns.parent_column_id
            INNER JOIN sys.columns AS referenced_columns
              ON referenced_columns.object_id = foreign_key_columns.referenced_object_id
             AND referenced_columns.column_id = foreign_key_columns.referenced_column_id
            WHERE parent_tables.is_ms_shipped = 0
            ORDER BY parent_schemas.name, parent_tables.name, foreign_keys.name,
                     foreign_key_columns.constraint_column_id
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """,
        // Check constraints and their exact provider definitions/trust state.
        """
        SELECT COALESCE((
            SELECT schemas.name AS [schema], tables.name AS [table], checks.name,
                   checks.definition, checks.is_disabled, checks.is_not_trusted
            FROM sys.check_constraints AS checks
            INNER JOIN sys.tables AS tables ON tables.object_id = checks.parent_object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, checks.name
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """,
        // Non-constraint indexes, key/include order, filters, storage, and flags.
        """
        SELECT COALESCE((
            SELECT schemas.name AS [schema], tables.name AS [table], indexes.name,
                   indexes.is_unique, indexes.filter_definition,
                   indexes.type_desc, data_spaces.name AS data_space,
                   indexes.is_disabled, indexes.is_hypothetical,
                   indexes.fill_factor, indexes.is_padded,
                   indexes.ignore_dup_key, indexes.allow_row_locks,
                   indexes.allow_page_locks, indexes.optimize_for_sequential_key,
                   COALESCE(stats.no_recompute, 0) AS statistics_no_recompute,
                   index_columns.index_column_id, index_columns.key_ordinal,
                   index_columns.is_included_column,
                   index_columns.is_descending_key, columns.name AS column_name
            FROM sys.indexes AS indexes
            INNER JOIN sys.tables AS tables ON tables.object_id = indexes.object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.data_spaces AS data_spaces ON data_spaces.data_space_id = indexes.data_space_id
            LEFT JOIN sys.stats AS stats
              ON stats.object_id = indexes.object_id AND stats.stats_id = indexes.index_id
            INNER JOIN sys.index_columns AS index_columns
              ON index_columns.object_id = indexes.object_id
             AND index_columns.index_id = indexes.index_id
            INNER JOIN sys.columns AS columns
              ON columns.object_id = index_columns.object_id
             AND columns.column_id = index_columns.column_id
            WHERE tables.is_ms_shipped = 0
              AND indexes.name IS NOT NULL
              AND indexes.is_primary_key = 0
              AND indexes.is_unique_constraint = 0
            ORDER BY schemas.name, tables.name, indexes.name,
                     index_columns.is_included_column,
                     index_columns.key_ordinal, index_columns.index_column_id
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """,
        // Every reviewed absence boundary and database/storage option.
        """
        SELECT COALESCE((
            SELECT
              (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type IN (N'V',N'P',N'PC',N'FN',N'IF',N'TF',N'FS',N'FT',N'AF')) AS programmable_objects,
              (SELECT COUNT(*) FROM sys.triggers WHERE is_ms_shipped = 0) AS triggers,
              (SELECT COUNT(*) FROM sys.synonyms) AS synonyms,
              (SELECT COUNT(*) FROM sys.sequences) AS sequences,
              (SELECT COUNT(*) FROM sys.external_tables) AS external_tables,
              (SELECT COUNT(*) FROM sys.external_data_sources) AS external_data_sources,
              (SELECT COUNT(*) FROM sys.external_file_formats) AS external_file_formats,
              (SELECT COUNT(*) FROM sys.database_scoped_credentials) AS database_scoped_credentials,
              (SELECT COUNT(*) FROM sys.column_master_keys) AS column_master_keys,
              (SELECT COUNT(*) FROM sys.column_encryption_keys) AS column_encryption_keys,
              (SELECT COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1) AS user_assemblies,
              (SELECT COUNT(*) FROM sys.types WHERE is_user_defined = 1 OR is_table_type = 1) AS user_types,
              (SELECT COUNT(*) FROM sys.partition_functions) AS partition_functions,
              (SELECT COUNT(*) FROM sys.partition_schemes) AS partition_schemes,
              (SELECT COUNT(*) FROM sys.fulltext_catalogs) AS fulltext_catalogs,
              (SELECT COUNT(*) FROM sys.fulltext_indexes) AS fulltext_indexes,
              (SELECT COUNT(*) FROM sys.xml_schema_collections WHERE xml_collection_id > 1) AS xml_schema_collections,
              (SELECT COUNT(*) FROM sys.database_audit_specifications) AS audit_specifications,
              (SELECT COUNT(*) FROM sys.security_policies WHERE is_ms_shipped = 0) AS security_policies,
              (SELECT COUNT(*) FROM sys.database_firewall_rules) AS database_firewall_rules,
              (SELECT COUNT(*) FROM sys.change_tracking_tables) AS change_tracking_tables,
              (SELECT COUNT(*) FROM sys.periods) AS periods,
              (SELECT COUNT(*) FROM sys.sensitivity_classifications) AS sensitivity_classifications,
              (SELECT COUNT(*) FROM sys.extended_properties
               WHERE NOT (class = 0 AND major_id = 0 AND minor_id = 0
                          AND name = N'A365GatewayBootstrapInitializationIntent')) AS unexpected_extended_properties,
              (SELECT COUNT(*) FROM sys.schemas AS schemas
               LEFT JOIN sys.database_principals AS principals ON principals.principal_id = schemas.principal_id
               WHERE schemas.name NOT IN
                     (N'dbo',N'guest',N'sys',N'INFORMATION_SCHEMA',N'db_owner',N'db_accessadmin',
                      N'db_securityadmin',N'db_ddladmin',N'db_backupoperator',N'db_datareader',
                      N'db_datawriter',N'db_denydatareader',N'db_denydatawriter')
                  OR principals.name IS NULL OR principals.name <> schemas.name) AS unexpected_schemas,
              (SELECT COUNT(*) FROM sys.partitions AS partitions
               INNER JOIN sys.indexes AS indexes
                 ON indexes.object_id = partitions.object_id AND indexes.index_id = partitions.index_id
               INNER JOIN sys.tables AS tables ON tables.object_id = indexes.object_id
               LEFT JOIN sys.data_spaces AS data_spaces ON data_spaces.data_space_id = indexes.data_space_id
               WHERE tables.is_ms_shipped = 0 AND
                     (partitions.partition_number <> 1 OR partitions.data_compression_desc <> N'NONE'
                      OR indexes.type_desc NOT IN (N'HEAP',N'CLUSTERED',N'NONCLUSTERED')
                      OR data_spaces.name IS NULL OR data_spaces.name <> N'PRIMARY')) AS unexpected_storage,
              databases.state_desc, databases.user_access_desc, databases.is_read_only,
              databases.is_auto_close_on, databases.is_auto_shrink_on,
              databases.is_in_standby, databases.source_database_id,
              databases.containment_desc, databases.is_trustworthy_on,
              databases.is_db_chaining_on, databases.collation_name,
              databases.catalog_collation_type_desc,
              CASE WHEN databases.owner_sid = dbo_principal.sid THEN 1 ELSE 0 END AS owner_is_dbo
            FROM sys.databases AS databases
            LEFT JOIN sys.database_principals AS dbo_principal ON dbo_principal.name = N'dbo'
            WHERE databases.name = DB_NAME()
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ), N'[]');
        """
    ];

    public static async Task<string> ReadFingerprintAsync(
        SqlConnection connection,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (connection.State != System.Data.ConnectionState.Open)
            throw new InvalidOperationException("Database schema fingerprinting requires one already-open exact connection.");

        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(hasher, $"A365GatewayDatabaseSchemaContract|{ContractVersion}\n");
        foreach (var query in ContractQueries)
        {
            await using var command = connection.CreateCommand();
            command.CommandTimeout = 30;
            command.CommandText = query;
            var value = await command.ExecuteScalarAsync(cancellationToken);
            if (value is not string json || string.IsNullOrWhiteSpace(json))
                throw new InvalidOperationException("Azure SQL returned no bounded schema-attestation surface.");
            Append(hasher, json);
            Append(hasher, "\n");
        }

        return $"sha256:{Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant()}";
    }

    public static string ComputeFingerprintForTesting(IEnumerable<string> surfaces)
    {
        ArgumentNullException.ThrowIfNull(surfaces);
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(hasher, $"A365GatewayDatabaseSchemaContract|{ContractVersion}\n");
        var count = 0;
        foreach (var surface in surfaces)
        {
            if (string.IsNullOrWhiteSpace(surface))
                throw new ArgumentException("Schema-attestation surfaces must be nonempty.", nameof(surfaces));
            Append(hasher, surface);
            Append(hasher, "\n");
            count++;
        }
        if (count == 0)
            throw new ArgumentException("At least one schema-attestation surface is required.", nameof(surfaces));
        return $"sha256:{Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant()}";
    }

    private static void Append(IncrementalHash hash, string value) =>
        hash.AppendData(Encoding.UTF8.GetBytes(value));
}
