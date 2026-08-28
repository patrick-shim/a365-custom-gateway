-- FINALIZE ONLY after the N:N API revision is verified and every legacy API
-- revision that can write NULL-scope idempotency rows is at zero traffic.
-- The prepare migration must be applied first. Retained legacy NULL-scope rows
-- remain untouched and age out through the approved retention process.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.IdempotencyRecords', N'U') IS NULL
BEGIN
    THROW 50001, 'dbo.IdempotencyRecords does not exist.', 1;
END;

IF COL_LENGTH(N'dbo.IdempotencyRecords', N'AgentRegistrationId') IS NULL
BEGIN
    THROW 50002, 'Apply 20260825_scoped_idempotency.sql before finalizing.', 1;
END;

DECLARE @IdempotencyObjectId int = OBJECT_ID(N'dbo.IdempotencyRecords', N'U');

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS indexes
    WHERE indexes.[object_id] = @IdempotencyObjectId
      AND indexes.[name] = N'IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey'
      AND indexes.[is_unique] = 1
      AND indexes.[has_filter] = 1
      AND indexes.[filter_definition] = N'([AgentRegistrationId] IS NOT NULL)'
      AND 3 =
      (
          SELECT COUNT(*)
          FROM [sys].[index_columns] AS key_columns
          WHERE key_columns.[object_id] = indexes.[object_id]
            AND key_columns.[index_id] = indexes.[index_id]
            AND key_columns.[key_ordinal] > 0
      )
      AND EXISTS
      (
          SELECT 1
          FROM [sys].[index_columns] AS key_columns
          INNER JOIN [sys].[columns] AS columns
              ON columns.[object_id] = key_columns.[object_id]
             AND columns.[column_id] = key_columns.[column_id]
          WHERE key_columns.[object_id] = indexes.[object_id]
            AND key_columns.[index_id] = indexes.[index_id]
            AND
            (
                (key_columns.[key_ordinal] = 1 AND columns.[name] = N'AgentRegistrationId') OR
                (key_columns.[key_ordinal] = 2 AND columns.[name] = N'Endpoint') OR
                (key_columns.[key_ordinal] = 3 AND columns.[name] = N'IdempotencyKey')
            )
          GROUP BY key_columns.[index_id]
          HAVING COUNT(*) = 3
      )
)
BEGIN
    THROW 50003, 'The scoped filtered unique index is not ready.', 1;
END;

DECLARE @DropLegacyIndexSql nvarchar(max) = N'';

-- Drop only a legacy unique index whose sole key column is IdempotencyKey.
-- The scoped composite index and all non-unique retention indexes are retained.
SELECT @DropLegacyIndexSql +=
    N'DROP INDEX ' + QUOTENAME(indexes.[name]) +
    N' ON [dbo].[IdempotencyRecords];'
FROM [sys].[indexes] AS indexes
WHERE indexes.[object_id] = @IdempotencyObjectId
  AND indexes.[is_unique] = 1
  AND indexes.[is_primary_key] = 0
  AND
  (
      SELECT COUNT(*)
      FROM [sys].[index_columns] AS key_columns
      WHERE key_columns.[object_id] = indexes.[object_id]
        AND key_columns.[index_id] = indexes.[index_id]
        AND key_columns.[key_ordinal] > 0
  ) = 1
  AND EXISTS
  (
      SELECT 1
      FROM [sys].[index_columns] AS key_columns
      INNER JOIN [sys].[columns] AS columns
          ON columns.[object_id] = key_columns.[object_id]
         AND columns.[column_id] = key_columns.[column_id]
      WHERE key_columns.[object_id] = indexes.[object_id]
        AND key_columns.[index_id] = indexes.[index_id]
        AND key_columns.[key_ordinal] = 1
        AND columns.[name] = N'IdempotencyKey'
  );

IF @DropLegacyIndexSql <> N''
    EXEC [sys].[sp_executesql] @DropLegacyIndexSql;

COMMIT TRANSACTION;
