using FluentAssertions;
using Gateway.Infrastructure.Security;
using Gateway.IntegrationTests.Fixtures;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gateway.IntegrationTests.Security;

public sealed class AgentIngressCredentialServiceTests
{
    [Fact]
    public async Task IssueAndValidate_ShouldBindCredentialToExactlyOneRegistration()
    {
        await using var context = TestDbContextFactory.Create();
        var firstAgent = TestEntityFactory.CreateAgentRegistration("external-agent-01");
        var secondAgent = TestEntityFactory.CreateAgentRegistration("external-agent-02");
        context.AgentRegistrations.AddRange(firstAgent, secondAgent);

        var service = CreateService(context);
        var issuedFirst = service.Issue(firstAgent.Id, "admin-oid", DateTime.UtcNow);
        var issuedSecond = service.Issue(secondAgent.Id, "admin-oid", DateTime.UtcNow);
        await context.SaveChangesAsync();

        var firstIdentity = await service.ValidateAsync(
            issuedFirst.ApiKey,
            DateTime.UtcNow,
            CancellationToken.None);
        var secondIdentity = await service.ValidateAsync(
            issuedSecond.ApiKey,
            DateTime.UtcNow,
            CancellationToken.None);

        firstIdentity.Should().NotBeNull();
        firstIdentity!.AgentRegistrationId.Should().Be(firstAgent.Id);
        firstIdentity.ExternalAgentId.Should().Be("external-agent-01");
        secondIdentity.Should().NotBeNull();
        secondIdentity!.AgentRegistrationId.Should().Be(secondAgent.Id);
        secondIdentity.ExternalAgentId.Should().Be("external-agent-02");
        issuedFirst.ApiKey.Should().NotBe(issuedSecond.ApiKey);
    }

    [Fact]
    public async Task Issue_ShouldPersistOnlyHashAndSalt_NotRawApiKey()
    {
        await using var context = TestDbContextFactory.Create();
        var agent = TestEntityFactory.CreateAgentRegistration("hash-only-agent");
        context.AgentRegistrations.Add(agent);

        var service = CreateService(context);
        var issued = service.Issue(agent.Id, "admin-oid", DateTime.UtcNow);
        await context.SaveChangesAsync();
        context.ChangeTracker.Clear();

        var persisted = await context.AgentIngressCredentials.SingleAsync();
        persisted.SecretHash.Should().HaveCount(32);
        persisted.SecretSalt.Should().HaveCount(32);
        persisted.HashAlgorithm.Should().Be("SHA-256");
        Convert.ToBase64String(persisted.SecretHash)
            .Should().NotContain(issued.ApiKey);
        Convert.ToBase64String(persisted.SecretSalt)
            .Should().NotContain(issued.ApiKey);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-gateway-key")]
    [InlineData("a365gw_v1_not-a-guid.secret")]
    [InlineData("a365gw_v1_00000000000000000000000000000000.invalid+base64")]
    [InlineData("a365gw_v1_00000000000000000000000000000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    [InlineData("a365gw_v1_00000000000000000000000000000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    public async Task Validate_ShouldRejectMalformedCredentials(string presentedApiKey)
    {
        await using var context = TestDbContextFactory.Create();
        var service = CreateService(context);

        var result = await service.ValidateAsync(
            presentedApiKey,
            DateTime.UtcNow,
            CancellationToken.None);

        result.Should().BeNull();
    }

    [Fact]
    public async Task Validate_ShouldRejectModifiedSecret()
    {
        await using var context = TestDbContextFactory.Create();
        var agent = TestEntityFactory.CreateAgentRegistration("modified-key-agent");
        context.AgentRegistrations.Add(agent);
        var service = CreateService(context);
        var issued = service.Issue(agent.Id, "admin-oid", DateTime.UtcNow);
        await context.SaveChangesAsync();

        var lastCharacter = issued.ApiKey[^1] == 'A' ? 'B' : 'A';
        var modified = issued.ApiKey[..^1] + lastCharacter;
        var result = await service.ValidateAsync(
            modified,
            DateTime.UtcNow,
            CancellationToken.None);

        result.Should().BeNull();
    }

    [Fact]
    public async Task Validate_ShouldRejectExpiredOrRevokedCredential()
    {
        await using var context = TestDbContextFactory.Create();
        var agent = TestEntityFactory.CreateAgentRegistration("inactive-key-agent");
        context.AgentRegistrations.Add(agent);
        var issuedAt = DateTime.UtcNow.AddDays(-2);
        var service = CreateService(context, lifetimeDays: 1);
        var issued = service.Issue(agent.Id, "admin-oid", issuedAt);
        await context.SaveChangesAsync();

        var expired = await service.ValidateAsync(
            issued.ApiKey,
            DateTime.UtcNow,
            CancellationToken.None);
        expired.Should().BeNull();

        issued.Credential.ExpiresAtUtc = DateTime.UtcNow.AddDays(1);
        issued.Credential.RevokedAtUtc = DateTime.UtcNow;
        await context.SaveChangesAsync();

        var revoked = await service.ValidateAsync(
            issued.ApiKey,
            DateTime.UtcNow,
            CancellationToken.None);
        revoked.Should().BeNull();
    }

    [Fact]
    public async Task Validate_ShouldRejectDeletedRegistrationAndCorruptVerifierMetadata()
    {
        await using var context = TestDbContextFactory.Create();
        var agent = TestEntityFactory.CreateAgentRegistration("deleted-key-agent");
        context.AgentRegistrations.Add(agent);
        var service = CreateService(context);
        var issued = service.Issue(agent.Id, "admin-oid", DateTime.UtcNow);
        await context.SaveChangesAsync();

        agent.IsDeleted = true;
        await context.SaveChangesAsync();
        (await service.ValidateAsync(
            issued.ApiKey,
            DateTime.UtcNow,
            CancellationToken.None)).Should().BeNull();

        agent.IsDeleted = false;
        issued.Credential.SecretSalt = [0x01];
        issued.Credential.SecretHash = [0x02];
        await context.SaveChangesAsync();
        (await service.ValidateAsync(
            issued.ApiKey,
            DateTime.UtcNow,
            CancellationToken.None)).Should().BeNull();
    }

    [Fact]
    public async Task Revoke_ShouldRequireOverlapAndKeepReplacementUsable()
    {
        await using var context = TestDbContextFactory.Create();
        var agent = TestEntityFactory.CreateAgentRegistration("rotation-agent");
        context.AgentRegistrations.Add(agent);
        var service = CreateService(context);
        var now = DateTime.UtcNow;
        var first = service.Issue(agent.Id, "admin-oid", now.AddMinutes(-1));
        await context.SaveChangesAsync();

        var lastUsable = await service.RevokeAsync(
            agent.Id,
            first.Credential.Id,
            now,
            CancellationToken.None);

        lastUsable.Status.Should().Be(
            Gateway.Domain.Models.AgentIngressCredentialRevocationStatus.LastUsableCredential);
        first.Credential.RevokedAtUtc.Should().BeNull();

        var replacement = service.Issue(agent.Id, "admin-oid", now);
        await context.SaveChangesAsync();
        var revoked = await service.RevokeAsync(
            agent.Id,
            first.Credential.Id,
            now.AddSeconds(1),
            CancellationToken.None);
        await context.SaveChangesAsync();

        revoked.Status.Should().Be(
            Gateway.Domain.Models.AgentIngressCredentialRevocationStatus.Revoked);
        (await service.ValidateAsync(
            first.ApiKey,
            now.AddSeconds(2),
            CancellationToken.None)).Should().BeNull();
        (await service.ValidateAsync(
            replacement.ApiKey,
            now.AddSeconds(2),
            CancellationToken.None)).Should().NotBeNull();
    }

    [Fact]
    public async Task Revoke_ShouldNotCrossAgentBoundary()
    {
        await using var context = TestDbContextFactory.Create();
        var firstAgent = TestEntityFactory.CreateAgentRegistration("route-agent-01");
        var secondAgent = TestEntityFactory.CreateAgentRegistration("route-agent-02");
        context.AgentRegistrations.AddRange(firstAgent, secondAgent);
        var service = CreateService(context);
        var issued = service.Issue(firstAgent.Id, "admin-oid", DateTime.UtcNow);
        await context.SaveChangesAsync();

        var result = await service.RevokeAsync(
            secondAgent.Id,
            issued.Credential.Id,
            DateTime.UtcNow,
            CancellationToken.None);

        result.Status.Should().Be(
            Gateway.Domain.Models.AgentIngressCredentialRevocationStatus.NotFound);
        issued.Credential.RevokedAtUtc.Should().BeNull();
    }

    [Fact]
    public async Task List_ShouldReturnSafeMetadataOnlyInNewestFirstOrder()
    {
        await using var context = TestDbContextFactory.Create();
        var agent = TestEntityFactory.CreateAgentRegistration("metadata-agent");
        context.AgentRegistrations.Add(agent);
        var service = CreateService(context);
        var first = service.Issue(agent.Id, "admin-oid", DateTime.UtcNow.AddMinutes(-2));
        var second = service.Issue(agent.Id, "admin-oid", DateTime.UtcNow.AddMinutes(-1));
        await context.SaveChangesAsync();

        var metadata = await service.ListAsync(agent.Id, CancellationToken.None);

        metadata.Select(item => item.KeyId).Should().Equal(
            second.Credential.Id,
            first.Credential.Id);
        metadata.GetType().GenericTypeArguments.Should().NotContain(typeof(byte[]));
        typeof(Gateway.Domain.Models.AgentIngressCredentialMetadata)
            .GetProperties()
            .Select(property => property.Name)
            .Should().NotContain(["ApiKey", "SecretHash", "SecretSalt"]);
    }

    private static AgentIngressCredentialService CreateService(
        Gateway.Infrastructure.Persistence.GatewayDbContext context,
        int lifetimeDays = 365) =>
        new(
            context,
            Options.Create(new AgentIngressCredentialOptions
            {
                LifetimeDays = lifetimeDays
            }));
}
