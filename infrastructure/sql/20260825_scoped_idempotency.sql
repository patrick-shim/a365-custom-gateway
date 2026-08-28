SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.IdempotencyRecords', N'U') IS NULL
BEGIN
    THROW 50001, 'dbo.IdempotencyRecords does not exist.', 1;
END;

IF OBJECT_ID(N'dbo.AgentRegistrations', N'U') IS NULL
BEGIN
    THROW 50002, 'dbo.AgentRegistrations does not exist.', 1;
END;

DECLARE @IdempotencyObjectId int = OBJECT_ID(N'dbo.IdempotencyRecords', N'U');

-- Legacy records have no trustworthy registration ownership. Keep those rows
-- unchanged with a NULL scope until the approved retention process ages them
-- out; new application writes always supply a registration ID.
IF COL_LENGTH(N'dbo.IdempotencyRecords', N'AgentRegistrationId') IS NULL
BEGIN
    ALTER TABLE [dbo].[IdempotencyRecords]
        ADD [AgentRegistrationId] uniqueidentifier NULL;
END;

-- Force a new compilation boundary so SQL Server can bind the newly added
-- column in the foreign-key and index statements below. The transaction remains
-- open on the same connection across this batch separator.
GO

DECLARE @IdempotencyObjectId int = OBJECT_ID(N'dbo.IdempotencyRecords', N'U');

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[foreign_key_columns] AS foreign_key_columns
    WHERE foreign_key_columns.[parent_object_id] = @IdempotencyObjectId
      AND COL_NAME(
            foreign_key_columns.[parent_object_id],
            foreign_key_columns.[parent_column_id]) = N'AgentRegistrationId'
      AND foreign_key_columns.[referenced_object_id] =
            OBJECT_ID(N'dbo.AgentRegistrations', N'U')
      AND COL_NAME(
            foreign_key_columns.[referenced_object_id],
            foreign_key_columns.[referenced_column_id]) = N'Id'
)
BEGIN
    ALTER TABLE [dbo].[IdempotencyRecords] WITH CHECK
        ADD CONSTRAINT [FK_IdempotencyRecords_AgentRegistrations_AgentRegistrationId]
        FOREIGN KEY ([AgentRegistrationId])
        REFERENCES [dbo].[AgentRegistrations] ([Id])
        ON DELETE CASCADE;

    ALTER TABLE [dbo].[IdempotencyRecords]
        CHECK CONSTRAINT [FK_IdempotencyRecords_AgentRegistrations_AgentRegistrationId];
END;

-- Recreate any partial version of the named index as the required filtered
-- composite index. The filter deliberately excludes retained legacy rows.
IF EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS indexes
    WHERE indexes.[object_id] = @IdempotencyObjectId
      AND indexes.[name] = N'IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey'
      AND
      (
          [is_unique] = 0 OR
          [has_filter] = 0 OR
          [filter_definition] <> N'([AgentRegistrationId] IS NOT NULL)' OR
          3 <>
          (
              SELECT COUNT(*)
              FROM [sys].[index_columns] AS key_columns
              WHERE key_columns.[object_id] = @IdempotencyObjectId
                AND key_columns.[index_id] = [indexes].[index_id]
                AND key_columns.[key_ordinal] > 0
          ) OR
          NOT EXISTS
          (
              SELECT 1
              FROM [sys].[index_columns] AS key_columns
              INNER JOIN [sys].[columns] AS columns
                  ON columns.[object_id] = key_columns.[object_id]
                 AND columns.[column_id] = key_columns.[column_id]
              WHERE key_columns.[object_id] = @IdempotencyObjectId
                AND key_columns.[index_id] = [indexes].[index_id]
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
)
BEGIN
    DROP INDEX [IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey]
        ON [dbo].[IdempotencyRecords];
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes]
    WHERE [object_id] = @IdempotencyObjectId
      AND [name] = N'IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey'
)
BEGIN
    CREATE UNIQUE INDEX
        [IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey]
        ON [dbo].[IdempotencyRecords]
        ([AgentRegistrationId], [Endpoint], [IdempotencyKey])
        WHERE [AgentRegistrationId] IS NOT NULL;
END;

COMMIT TRANSACTION;
