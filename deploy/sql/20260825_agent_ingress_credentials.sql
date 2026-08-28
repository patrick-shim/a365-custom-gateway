SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.AgentRegistrations', N'U') IS NULL
BEGIN
    THROW 50001, 'dbo.AgentRegistrations does not exist.', 1;
END;

IF OBJECT_ID(N'dbo.AgentIngressCredentials', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[AgentIngressCredentials]
    (
        [Id] uniqueidentifier NOT NULL,
        [AgentRegistrationId] uniqueidentifier NOT NULL,
        [FormatVersion] int NOT NULL,
        [HashAlgorithm] nvarchar(32) NOT NULL,
        [SecretSalt] varbinary(64) NOT NULL,
        [SecretHash] varbinary(64) NOT NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [CreatedByObjectId] nvarchar(64) NOT NULL,
        [ExpiresAtUtc] datetime2 NOT NULL,
        [RevokedAtUtc] datetime2 NULL,
        CONSTRAINT [PK_AgentIngressCredentials]
            PRIMARY KEY ([Id]),
        CONSTRAINT [FK_AgentIngressCredentials_AgentRegistrations]
            FOREIGN KEY ([AgentRegistrationId])
            REFERENCES [dbo].[AgentRegistrations] ([Id])
            ON DELETE CASCADE
    );

    CREATE INDEX [IX_AgentIngressCredentials_AgentRegistrationId]
        ON [dbo].[AgentIngressCredentials] ([AgentRegistrationId]);

    CREATE INDEX [IX_AgentIngressCredentials_ExpiresAtUtc]
        ON [dbo].[AgentIngressCredentials] ([ExpiresAtUtc]);
END;

DECLARE @CredentialObjectId int = OBJECT_ID(N'dbo.AgentIngressCredentials', N'U');

IF @CredentialObjectId IS NULL
BEGIN
    THROW 50002, 'dbo.AgentIngressCredentials was not created.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM
    (
        VALUES
            (N'Id', TYPE_ID(N'uniqueidentifier'), 16, 0, 0),
            (N'AgentRegistrationId', TYPE_ID(N'uniqueidentifier'), 16, 0, 0),
            (N'FormatVersion', TYPE_ID(N'int'), 4, 0, 0),
            (N'HashAlgorithm', TYPE_ID(N'nvarchar'), 64, 0, 0),
            (N'SecretSalt', TYPE_ID(N'varbinary'), 64, 0, 0),
            (N'SecretHash', TYPE_ID(N'varbinary'), 64, 0, 0),
            (N'CreatedAtUtc', TYPE_ID(N'datetime2'), 8, 7, 0),
            (N'CreatedByObjectId', TYPE_ID(N'nvarchar'), 128, 0, 0),
            (N'ExpiresAtUtc', TYPE_ID(N'datetime2'), 8, 7, 0),
            (N'RevokedAtUtc', TYPE_ID(N'datetime2'), 8, 7, 1)
    ) AS expected ([Name], [SystemTypeId], [MaxLength], [Scale], [IsNullable])
    LEFT JOIN [sys].[columns] AS columns
        ON columns.[object_id] = @CredentialObjectId
       AND columns.[name] = expected.[Name]
    WHERE columns.[column_id] IS NULL
       OR columns.[system_type_id] <> expected.[SystemTypeId]
       OR columns.[max_length] <> expected.[MaxLength]
       OR columns.[scale] <> expected.[Scale]
       OR columns.[is_nullable] <> expected.[IsNullable]
)
BEGIN
    THROW 50003, 'dbo.AgentIngressCredentials has an incompatible schema.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS indexes
    INNER JOIN [sys].[index_columns] AS key_columns
        ON key_columns.[object_id] = indexes.[object_id]
       AND key_columns.[index_id] = indexes.[index_id]
       AND key_columns.[key_ordinal] = 1
    INNER JOIN [sys].[columns] AS columns
        ON columns.[object_id] = key_columns.[object_id]
       AND columns.[column_id] = key_columns.[column_id]
    WHERE indexes.[object_id] = @CredentialObjectId
      AND indexes.[is_primary_key] = 1
      AND indexes.[is_unique] = 1
      AND columns.[name] = N'Id'
      AND 1 =
      (
          SELECT COUNT(*)
          FROM [sys].[index_columns] AS all_key_columns
          WHERE all_key_columns.[object_id] = indexes.[object_id]
            AND all_key_columns.[index_id] = indexes.[index_id]
            AND all_key_columns.[key_ordinal] > 0
      )
)
BEGIN
    THROW 50004, 'dbo.AgentIngressCredentials requires an Id primary key.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[foreign_keys] AS foreign_keys
    INNER JOIN [sys].[foreign_key_columns] AS foreign_key_columns
        ON foreign_key_columns.[constraint_object_id] = foreign_keys.[object_id]
    WHERE foreign_keys.[parent_object_id] = @CredentialObjectId
      AND foreign_keys.[referenced_object_id] = OBJECT_ID(N'dbo.AgentRegistrations', N'U')
      AND foreign_keys.[delete_referential_action] = 1
      AND foreign_keys.[is_disabled] = 0
      AND foreign_keys.[is_not_trusted] = 0
      AND COL_NAME(
            foreign_key_columns.[parent_object_id],
            foreign_key_columns.[parent_column_id]) = N'AgentRegistrationId'
      AND COL_NAME(
            foreign_key_columns.[referenced_object_id],
            foreign_key_columns.[referenced_column_id]) = N'Id'
)
BEGIN
    THROW 50005, 'dbo.AgentIngressCredentials requires the trusted cascading registration foreign key.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS indexes
    INNER JOIN [sys].[index_columns] AS key_columns
        ON key_columns.[object_id] = indexes.[object_id]
       AND key_columns.[index_id] = indexes.[index_id]
       AND key_columns.[key_ordinal] = 1
    INNER JOIN [sys].[columns] AS columns
        ON columns.[object_id] = key_columns.[object_id]
       AND columns.[column_id] = key_columns.[column_id]
    WHERE indexes.[object_id] = @CredentialObjectId
      AND indexes.[is_unique] = 0
      AND columns.[name] = N'AgentRegistrationId'
)
BEGIN
    THROW 50006, 'dbo.AgentIngressCredentials requires its registration lookup index.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS indexes
    INNER JOIN [sys].[index_columns] AS key_columns
        ON key_columns.[object_id] = indexes.[object_id]
       AND key_columns.[index_id] = indexes.[index_id]
       AND key_columns.[key_ordinal] = 1
    INNER JOIN [sys].[columns] AS columns
        ON columns.[object_id] = key_columns.[object_id]
       AND columns.[column_id] = key_columns.[column_id]
    WHERE indexes.[object_id] = @CredentialObjectId
      AND indexes.[is_unique] = 0
      AND columns.[name] = N'ExpiresAtUtc'
)
BEGIN
    THROW 50007, 'dbo.AgentIngressCredentials requires its expiry lookup index.', 1;
END;

COMMIT TRANSACTION;
