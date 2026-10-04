using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed partial class OutboxRepository
{
    private async Task<IReadOnlyList<OutboxMessage>> ClaimPendingPostgresAsync(
        int batchSize, DateTime utcNow, DateTime claimExpiresAtUtc, CancellationToken ct)
    {
        // One statement owns the claim across API/worker replicas. SKIP LOCKED lets
        // other relays claim different messages without waiting for this batch.
        return await _dbContext.OutboxMessages.FromSqlInterpolated($"""
            WITH candidates AS (
                SELECT "Id" FROM "OutboxMessages"
                WHERE (("Status" = 'Pending' AND ("NextRetryAtUtc" IS NULL OR "NextRetryAtUtc" <= {utcNow}))
                    OR ("Status" = 'Processing' AND "NextRetryAtUtc" <= {utcNow}))
                  AND "Destination" = 'gateway-provisioning-v3'
                ORDER BY "CreatedAtUtc", "Id"
                LIMIT {batchSize} FOR UPDATE SKIP LOCKED
            )
            UPDATE "OutboxMessages" AS message
            SET "Status" = 'Processing', "NextRetryAtUtc" = {claimExpiresAtUtc}
            FROM candidates WHERE message."Id" = candidates."Id"
            RETURNING message.*
            """).AsNoTracking().ToListAsync(ct);
    }

}
