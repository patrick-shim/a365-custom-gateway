using System.Text.Json;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Queries;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class CredentialLifecycleTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task Lost_key_is_replaced_not_recovered_and_revoke_is_scoped_repeatable_and_preserves_last_usable_key()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var agent = TestData.Agent();
        context.Add(agent);
        await context.SaveChangesAsync();
        var harness = new GatewaySqlHarness(context);
        var original = await harness.Issue().Handle(new(agent.Id, TestData.Caller), default);
        var lastKey = await Assert.ThrowsAsync<ConflictException>(() =>
            harness.Revoke().Handle(new(agent.Id, original.GatewayCredential.KeyId, TestData.Caller), default));
        Assert.Equal(ErrorCodes.AGENT_INGRESS_CREDENTIAL_LAST_USABLE, lastKey.ErrorCode);
        Assert.Null((await context.AgentIngressCredentials.SingleAsync()).RevokedAtUtc);

        var replacement = await harness.Issue().Handle(new(agent.Id, TestData.Caller), default);
        Assert.NotEqual(original.GatewayCredential.ApiKey, replacement.GatewayCredential.ApiKey);
        Assert.NotEqual(original.GatewayCredential.KeyId, replacement.GatewayCredential.KeyId);
        Assert.NotNull(await harness.Credentials.ValidateAsync(original.GatewayCredential.ApiKey, DateTime.UtcNow, default));
        var identity = await harness.Credentials.ValidateAsync(replacement.GatewayCredential.ApiKey, DateTime.UtcNow, default);
        Assert.NotNull(identity);
        Assert.Equal(agent.Id, identity.AgentRegistrationId);
        Assert.Equal(agent.ExternalAgentId.Value, identity.ExternalAgentId);

        var listed = await new ListAgentIngressCredentialsHandler(
            new AgentRegistrationRepository(context), harness.Credentials).Handle(new(agent.Id), default);
        var metadata = JsonSerializer.Serialize(listed);
        Assert.DoesNotContain("ApiKey", metadata);
        Assert.DoesNotContain("Secret", metadata);
        Assert.DoesNotContain(original.GatewayCredential.ApiKey, metadata);
        Assert.DoesNotContain(replacement.GatewayCredential.ApiKey, metadata);

        var revoked = await harness.Revoke().Handle(new(agent.Id, original.GatewayCredential.KeyId, TestData.Caller), default);
        Assert.False(revoked.AlreadyRevoked);
        var replay = await harness.Revoke().Handle(new(agent.Id, original.GatewayCredential.KeyId, TestData.Caller), default);
        Assert.True(replay.AlreadyRevoked);
        Assert.Equal(revoked.Credential.RevokedAtUtc, replay.Credential.RevokedAtUtc);
        Assert.Null(await harness.Credentials.ValidateAsync(original.GatewayCredential.ApiKey, DateTime.UtcNow, default));
        Assert.NotNull(await harness.Credentials.ValidateAsync(replacement.GatewayCredential.ApiKey, DateTime.UtcNow, default));
        Assert.Equal(1, await context.AuditEvents.CountAsync(item => item.EventType == "GatewayCredentialRevoked"));
        var audit = JsonSerializer.Serialize(await context.AuditEvents.AsNoTracking().ToListAsync());
        Assert.DoesNotContain(original.GatewayCredential.ApiKey, audit);
        Assert.DoesNotContain(replacement.GatewayCredential.ApiKey, audit);
    }

    [Fact]
    public async Task Stored_keys_are_salted_hashes_and_expiry_is_exclusive()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var agent = TestData.Agent();
        context.Add(agent);
        var service = new GatewaySqlHarness(context).Credentials;
        var issued = service.Issue(agent.Id, TestData.Caller, TestData.Now);
        await context.SaveChangesAsync();
        var stored = await context.AgentIngressCredentials.AsNoTracking().SingleAsync();
        Assert.Equal(32, stored.SecretSalt.Length);
        Assert.Equal(32, stored.SecretHash.Length);
        Assert.Equal("SHA-256", stored.HashAlgorithm);
        Assert.DoesNotContain(issued.ApiKey, JsonSerializer.Serialize(new
        {
            stored.Id, stored.SecretHash, stored.SecretSalt, stored.CreatedByObjectId, stored.ExpiresAtUtc
        }));
        Assert.Equal(TestData.Now.AddDays(365), stored.ExpiresAtUtc);
        Assert.NotNull(await service.ValidateAsync(issued.ApiKey, stored.ExpiresAtUtc.AddTicks(-1), default));
        Assert.Null(await service.ValidateAsync(issued.ApiKey, stored.ExpiresAtUtc, default));
        var separator = issued.ApiKey.IndexOf('.') + 1;
        var tampered = issued.ApiKey[..separator] + (issued.ApiKey[separator] == 'A' ? 'B' : 'A') + issued.ApiKey[(separator + 1)..];
        Assert.Null(await service.ValidateAsync(tampered, TestData.Now, default));
    }

    [Theory]
    [InlineData("")]
    [InlineData("Bearer synthetic")]
    [InlineData("a365gw_v2_00000000000040008000000000000001.invalid")]
    [InlineData("a365gw_v1_00000000000040008000000000000001.short")]
    public async Task Malformed_keys_are_not_accepted(string key)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        Assert.Null(await new GatewaySqlHarness(context).Credentials.ValidateAsync(key, TestData.Now, default));
    }

    [Fact]
    public async Task A_key_cannot_be_revoked_through_a_different_registration_and_deleted_agent_keys_stop_authenticating()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var first = TestData.Agent();
        var second = TestData.Agent();
        second.BlueprintId = first.BlueprintId;
        context.AddRange(first, second);
        var service = new GatewaySqlHarness(context).Credentials;
        var issued = service.Issue(first.Id, TestData.Caller, TestData.Now);
        await context.SaveChangesAsync();
        Assert.Equal(AgentIngressCredentialRevocationStatus.NotFound,
            (await service.RevokeAsync(second.Id, issued.Credential.Id, TestData.Now, default)).Status);
        first.IsDeleted = true;
        first.Status = AgentStatus.Deleted;
        await context.SaveChangesAsync();
        Assert.Null(await service.ValidateAsync(issued.ApiKey, TestData.Now, default));
    }

    [Theory]
    [InlineData(AgentStatus.Deleting)]
    [InlineData(AgentStatus.Deleted)]
    public async Task Issue_rejects_agents_being_removed(AgentStatus status)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var agent = TestData.Agent();
        agent.Status = status;
        context.Add(agent);
        await context.SaveChangesAsync();
        var issue = new GatewaySqlHarness(context).Issue();
        if (status == AgentStatus.Deleting)
            await Assert.ThrowsAsync<InvalidStateTransitionException>(() => issue.Handle(new(agent.Id, TestData.Caller), default));
        else
            await Assert.ThrowsAsync<NotFoundException>(() => issue.Handle(new(agent.Id, TestData.Caller), default));
        Assert.Equal(0, await context.AgentIngressCredentials.CountAsync());
    }

    [Fact]
    public async Task Credential_issue_and_audit_are_one_SQL_transaction()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = TestData.Agent();
        await using (var seed = database.CreateContext())
        {
            seed.Add(agent);
            await seed.SaveChangesAsync();
        }
        await database.ExecuteAsync("""
            ALTER TABLE dbo.AuditEvents ADD CONSTRAINT CK_M1_RejectCredentialAudit
            CHECK ([EventType] <> N'GatewayCredentialIssued');
            """);
        await using (var context = database.CreateContext())
        {
            var error = await Assert.ThrowsAsync<DbUpdateException>(() =>
                new GatewaySqlHarness(context).Issue().Handle(new(agent.Id, TestData.Owner), default));
            Assert.Equal(547, Assert.IsType<SqlException>(error.InnerException).Number);
        }
        await using var verify = database.CreateContext();
        Assert.Equal(0, await verify.AgentIngressCredentials.CountAsync());
        Assert.Equal(0, await verify.AuditEvents.CountAsync());
        Assert.Equal(TestData.Caller, (await verify.AgentRegistrations.SingleAsync()).UpdatedByObjectId);
    }
}
