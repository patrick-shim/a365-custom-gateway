SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.IngressRateLimitBuckets', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[IngressRateLimitBuckets]
    (
        [ScopeType] tinyint NOT NULL,
        [ScopeId] uniqueidentifier NOT NULL,
        [WindowStartUtc] datetime2(0) NOT NULL,
        [RequestCount] int NOT NULL,
        [UpdatedAtUtc] datetime2(7) NOT NULL,
        CONSTRAINT [PK_IngressRateLimitBuckets]
            PRIMARY KEY CLUSTERED ([ScopeType], [ScopeId]),
        CONSTRAINT [CK_IngressRateLimitBuckets_ScopeType]
            CHECK ([ScopeType] IN (0, 1, 2)),
        CONSTRAINT [CK_IngressRateLimitBuckets_RequestCount]
            CHECK ([RequestCount] >= 0)
    );
END;

DECLARE @BucketObjectId int = OBJECT_ID(N'dbo.IngressRateLimitBuckets', N'U');

IF @BucketObjectId IS NULL
BEGIN
    THROW 50001, 'dbo.IngressRateLimitBuckets was not created.', 1;
END;

IF COL_LENGTH(N'dbo.IngressRateLimitBuckets', N'ScopeType') IS NULL OR
   COL_LENGTH(N'dbo.IngressRateLimitBuckets', N'ScopeId') IS NULL OR
   COL_LENGTH(N'dbo.IngressRateLimitBuckets', N'WindowStartUtc') IS NULL OR
   COL_LENGTH(N'dbo.IngressRateLimitBuckets', N'RequestCount') IS NULL OR
   COL_LENGTH(N'dbo.IngressRateLimitBuckets', N'UpdatedAtUtc') IS NULL
BEGIN
    THROW 50002, 'dbo.IngressRateLimitBuckets has an incompatible column shape.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM
    (
        VALUES
            (N'ScopeType', TYPE_ID(N'tinyint'), 1, 0),
            (N'ScopeId', TYPE_ID(N'uniqueidentifier'), 16, 0),
            -- datetime2(0) uses six storage bytes; precision 5-7 uses eight.
            (N'WindowStartUtc', TYPE_ID(N'datetime2'), 6, 0),
            (N'RequestCount', TYPE_ID(N'int'), 4, 0),
            (N'UpdatedAtUtc', TYPE_ID(N'datetime2'), 8, 7)
    ) AS expected ([Name], [SystemTypeId], [MaxLength], [Scale])
    LEFT JOIN [sys].[columns] AS columns
        ON columns.[object_id] = @BucketObjectId
       AND columns.[name] = expected.[Name]
    WHERE columns.[column_id] IS NULL
       OR columns.[system_type_id] <> expected.[SystemTypeId]
       OR columns.[max_length] <> expected.[MaxLength]
       OR columns.[scale] <> expected.[Scale]
       OR columns.[is_nullable] <> 0
)
BEGIN
    THROW 50006, 'dbo.IngressRateLimitBuckets has incompatible column types or nullability.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS indexes
    WHERE indexes.[object_id] = @BucketObjectId
      AND indexes.[is_primary_key] = 1
      AND indexes.[is_unique] = 1
      AND 2 =
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
                (key_columns.[key_ordinal] = 1 AND columns.[name] = N'ScopeType') OR
                (key_columns.[key_ordinal] = 2 AND columns.[name] = N'ScopeId')
            )
          GROUP BY key_columns.[index_id]
          HAVING COUNT(*) = 2
      )
)
BEGIN
    THROW 50003, 'dbo.IngressRateLimitBuckets requires a unique ScopeType/ScopeId primary key.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[check_constraints]
    WHERE [parent_object_id] = @BucketObjectId
      AND [name] = N'CK_IngressRateLimitBuckets_ScopeType'
      AND [is_disabled] = 0
      AND [is_not_trusted] = 0
)
BEGIN
    THROW 50004, 'dbo.IngressRateLimitBuckets is missing its scope constraint.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[check_constraints]
    WHERE [parent_object_id] = @BucketObjectId
      AND [name] = N'CK_IngressRateLimitBuckets_RequestCount'
      AND [is_disabled] = 0
      AND [is_not_trusted] = 0
)
BEGIN
    THROW 50005, 'dbo.IngressRateLimitBuckets is missing its count constraint.', 1;
END;

COMMIT TRANSACTION;
