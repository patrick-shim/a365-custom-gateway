SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'A365Gateway:Migration:ActiveAgentIdentityUniqueness',
    @LockMode = N'Exclusive',
    @LockOwner = N'Transaction',
    @LockTimeout = 60000;

IF @LockResult < 0
BEGIN
    THROW 50000, 'Could not serialize the active child Agent Identity uniqueness migration.', 1;
END;

IF OBJECT_ID(N'dbo.AgentRegistrations', N'U') IS NULL
BEGIN
    THROW 50001, 'dbo.AgentRegistrations does not exist.', 1;
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'AgentIdentityObjectId') IS NULL
BEGIN
    THROW 50002, 'AgentIdentityObjectId does not exist on dbo.AgentRegistrations.', 1;
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'IsDeleted') IS NULL
BEGIN
    THROW 50003, 'IsDeleted does not exist on dbo.AgentRegistrations.', 1;
END;

DECLARE @AgentRegistrationsObjectId int =
    OBJECT_ID(N'dbo.AgentRegistrations', N'U');
DECLARE @IndexName sysname =
    N'IX_AgentRegistrations_AgentIdentityObjectId';
DECLARE @ExistingIndexId int =
(
    SELECT indexes.[index_id]
    FROM [sys].[indexes] AS indexes
    WHERE indexes.[object_id] = @AgentRegistrationsObjectId
      AND indexes.[name] = @IndexName
);
DECLARE @NormalizedFilter nvarchar(4000);

IF @ExistingIndexId IS NOT NULL
BEGIN
    SELECT @NormalizedFilter =
        LOWER(
            REPLACE(
                REPLACE(
                    REPLACE(
                        REPLACE(
                            REPLACE(
                                REPLACE(
                                    REPLACE(indexes.[filter_definition], N'[', N''),
                                    N']',
                                    N''),
                                N'(',
                                N''),
                            N')',
                            N''),
                        N' ',
                        N''),
                    NCHAR(9),
                    N''),
                NCHAR(10),
                N''))
    FROM [sys].[indexes] AS indexes
    WHERE indexes.[object_id] = @AgentRegistrationsObjectId
      AND indexes.[index_id] = @ExistingIndexId;

    SET @NormalizedFilter = REPLACE(@NormalizedFilter, NCHAR(13), N'');

    IF EXISTS
    (
        SELECT 1
        FROM [sys].[indexes] AS indexes
        WHERE indexes.[object_id] = @AgentRegistrationsObjectId
          AND indexes.[index_id] = @ExistingIndexId
          AND
          (
              indexes.[is_unique] <> 1 OR
              indexes.[has_filter] <> 1 OR
              indexes.[is_disabled] <> 0 OR
              indexes.[is_hypothetical] <> 0
          )
    )
    OR @NormalizedFilter <> N'agentidentityobjectidisnotnullandisdeleted=0'
    OR 1 <>
    (
        SELECT COUNT(*)
        FROM [sys].[index_columns] AS key_columns
        WHERE key_columns.[object_id] = @AgentRegistrationsObjectId
          AND key_columns.[index_id] = @ExistingIndexId
          AND key_columns.[key_ordinal] > 0
    )
    OR NOT EXISTS
    (
        SELECT 1
        FROM [sys].[index_columns] AS key_columns
        INNER JOIN [sys].[columns] AS columns
            ON columns.[object_id] = key_columns.[object_id]
           AND columns.[column_id] = key_columns.[column_id]
        WHERE key_columns.[object_id] = @AgentRegistrationsObjectId
          AND key_columns.[index_id] = @ExistingIndexId
          AND key_columns.[key_ordinal] = 1
          AND columns.[name] = N'AgentIdentityObjectId'
    )
    BEGIN
        THROW 50004, 'The existing child Agent Identity index does not match the required active-row uniqueness contract.', 1;
    END;
END;

IF @ExistingIndexId IS NULL
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM [sys].[indexes] AS indexes
        WHERE indexes.[object_id] = @AgentRegistrationsObjectId
          AND indexes.[name] <> @IndexName
          AND indexes.[is_unique] = 1
          AND indexes.[is_primary_key] = 0
          AND 1 =
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
                AND key_columns.[key_ordinal] = 1
                AND columns.[name] = N'AgentIdentityObjectId'
          )
    )
    BEGIN
        THROW 50005, 'A differently named unique child Agent Identity index requires review.', 1;
    END;

    IF EXISTS
    (
        SELECT [AgentIdentityObjectId]
        FROM [dbo].[AgentRegistrations] WITH (UPDLOCK, HOLDLOCK)
        WHERE [AgentIdentityObjectId] IS NOT NULL
          AND [IsDeleted] = 0
        GROUP BY [AgentIdentityObjectId]
        HAVING COUNT_BIG(*) > 1
    )
    BEGIN
        THROW 50006, 'Active registrations already share an AgentIdentityObjectId; no data was changed.', 1;
    END;

    CREATE UNIQUE INDEX [IX_AgentRegistrations_AgentIdentityObjectId]
        ON [dbo].[AgentRegistrations] ([AgentIdentityObjectId])
        WHERE [AgentIdentityObjectId] IS NOT NULL
          AND [IsDeleted] = 0;
END;

COMMIT TRANSACTION;
