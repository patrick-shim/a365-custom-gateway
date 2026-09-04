SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- Prompt Shields is a per-agent control, not a blueprint-level one. Recording the
-- Agent 365 identity alongside each verdict makes a stored evaluation answer
-- "which agent made this call" on its own, instead of requiring a join back
-- through the gateway registration that may since have been re-provisioned.
--
-- Both columns are nullable on purpose: an agent whose Agent 365 provisioning has
-- not completed still receives a real verdict, and an absent identity is recorded
-- as absent rather than backfilled with a placeholder.

IF COL_LENGTH('dbo.PromptEvaluationRecords', 'Agent365AgentId') IS NULL
BEGIN
    ALTER TABLE dbo.PromptEvaluationRecords
        ADD Agent365AgentId uniqueidentifier NULL;
END;

IF COL_LENGTH('dbo.PromptEvaluationRecords', 'BlueprintId') IS NULL
BEGIN
    ALTER TABLE dbo.PromptEvaluationRecords
        ADD BlueprintId uniqueidentifier NULL;
END;

COMMIT TRANSACTION;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_PromptEvaluationRecords_Agent365AgentId_CreatedAtUtc'
      AND object_id = OBJECT_ID('dbo.PromptEvaluationRecords'))
BEGIN
    CREATE INDEX IX_PromptEvaluationRecords_Agent365AgentId_CreatedAtUtc
        ON dbo.PromptEvaluationRecords(Agent365AgentId, CreatedAtUtc);
END;
