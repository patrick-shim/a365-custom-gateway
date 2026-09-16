SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'A365Gateway:Migration:CapabilityPreparationReceipts',
    @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 60000;
IF @LockResult < 0
    THROW 50000, 'Could not serialize capability preparation receipt migration.', 1;
IF OBJECT_ID(N'dbo.ProtectionCapabilities', N'U') IS NULL
    THROW 50001, 'Protection governance is required before capability preparation receipts.', 1;
IF OBJECT_ID(N'dbo.CapabilityPreparationHistory', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[CapabilityPreparationHistory] (
        [Id] uniqueidentifier NOT NULL,
        [DeploymentOwnershipId] uniqueidentifier NOT NULL,
        [ApprovedPlanFingerprint] nvarchar(71) NOT NULL,
        [ReceiptFingerprint] nvarchar(71) NOT NULL,
        [PreviousReceiptFingerprint] nvarchar(71) NULL,
        [OriginalCapabilityFactsHash] nvarchar(71) NOT NULL,
        [PriorCapabilityFactsJson] nvarchar(max) NOT NULL,
        [TargetCapabilityFactsJson] nvarchar(max) NOT NULL,
        [ReceiptJson] nvarchar(max) NOT NULL,
        [RecordedAtUtc] datetime2 NOT NULL,
        CONSTRAINT [PK_CapabilityPreparationHistory] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_CapabilityPreparationHistory_Json] CHECK
            (ISJSON([PriorCapabilityFactsJson]) = 1 AND ISJSON([TargetCapabilityFactsJson]) = 1 AND ISJSON([ReceiptJson]) = 1)
    );
    CREATE UNIQUE INDEX [IX_CapabilityPreparationHistory_ReceiptFingerprint]
        ON [dbo].[CapabilityPreparationHistory] ([ReceiptFingerprint]);
    CREATE UNIQUE INDEX [IX_CapabilityPreparationHistory_DeploymentOwnershipId_ApprovedPlanFingerprint]
        ON [dbo].[CapabilityPreparationHistory] ([DeploymentOwnershipId], [ApprovedPlanFingerprint]);
END;
-- No original capability row or accepted bootstrap evidence is modified by this migration.
-- Startup appends prior facts + pinned prepared receipt before updating the effective projection.
COMMIT TRANSACTION;
