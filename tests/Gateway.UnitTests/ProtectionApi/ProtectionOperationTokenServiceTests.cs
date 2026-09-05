using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class ProtectionOperationTokenServiceTests
{
    private static readonly DateTime Now =
        new(2026, 9, 5, 10, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void ReviewAndConfirmation_AreOneTimeSaltedVerifierBindings()
    {
        var clock = new TestTimeProvider(Now);
        var service = new ProtectionOperationTokenService(clock);
        var actor = new ProtectionActor(
            Guid.Parse("11111111-1111-4111-8111-111111111111"),
            "22222222-2222-4222-8222-222222222222");
        var operation = CreateOperation(actor);

        var review = service.IssueReview(
            operation,
            expectedRowVersion: "AQIDBAUGBwg=",
            new { tenantId = actor.TenantId });
        operation.ReviewedPayloadHash = review.ReviewedPayloadHash;
        operation.ConfirmationVerifier = review.Verifier;

        Encoding.UTF8.GetString(review.Verifier.VerifierHash.Span)
            .Should().NotContain(review.Token);
        review.Verifier.VerifierSalt.Length.Should().BeGreaterThanOrEqualTo(16);

        var confirmation = service.ExchangeReview(
            operation,
            actor,
            review.Token);
        operation.ConfirmationVerifier = confirmation.Verifier;

        var validated = service.ValidateConfirmation(
            operation,
            actor,
            confirmation.Token,
            "AQIDBAUGBwg=");
        validated.Payload.GetProperty("tenantId").GetGuid().Should().Be(actor.TenantId);

        operation.ConfirmationVerifier.MarkConsumed(Now);
        var replay = () => service.ValidateConfirmation(
            operation,
            actor,
            confirmation.Token,
            "AQIDBAUGBwg=");
        replay.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
    }

    [Fact]
    public void ReviewToken_IsBoundToActorTenantTargetPayloadRowVersionAndExpiry()
    {
        var clock = new TestTimeProvider(Now);
        var service = new ProtectionOperationTokenService(clock);
        var actor = new ProtectionActor(
            Guid.Parse("11111111-1111-4111-8111-111111111111"),
            "22222222-2222-4222-8222-222222222222");
        var operation = CreateOperation(actor);
        var review = service.IssueReview(
            operation,
            expectedRowVersion: "*",
            new { value = "reviewed-value" });
        operation.ReviewedPayloadHash = review.ReviewedPayloadHash;
        operation.ConfirmationVerifier = review.Verifier;

        var wrongActor = new ProtectionActor(
            actor.TenantId,
            "33333333-3333-4333-8333-333333333333");
        var wrongUser = () => service.ExchangeReview(operation, wrongActor, review.Token);
        wrongUser.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

        operation.TargetIdentifier = "different-target";
        var wrongTarget = () => service.ExchangeReview(operation, actor, review.Token);
        wrongTarget.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

        operation.TargetIdentifier = actor.TenantId.ToString("D");
        clock.Advance(TimeSpan.FromMinutes(6));
        var expired = () => service.ExchangeReview(operation, actor, review.Token);
        expired.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROTECTION_REVIEW_EXPIRED);
    }

    [Fact]
    public void InvalidToken_UsesConstantTimeSaltedVerifierComparison()
    {
        var clock = new TestTimeProvider(Now);
        var service = new ProtectionOperationTokenService(clock);
        var actor = new ProtectionActor(
            Guid.Parse("11111111-1111-4111-8111-111111111111"),
            "22222222-2222-4222-8222-222222222222");
        var operation = CreateOperation(actor);
        var review = service.IssueReview(operation, "*", new { value = "payload" });
        operation.ReviewedPayloadHash = review.ReviewedPayloadHash;
        operation.ConfirmationVerifier = review.Verifier;

        var invalid = review.Token[..^1] + (review.Token[^1] == 'A' ? "B" : "A");
        var action = () => service.ExchangeReview(operation, actor, invalid);

        action.Should().Throw<DomainException>()
            .Which.ErrorCode.Should().Be(ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

        var candidate = Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(review.Token),
            review.Verifier.VerifierSalt.Span,
            ProtectionOperationTokenService.Pbkdf2Iterations,
            HashAlgorithmName.SHA256,
            review.Verifier.VerifierHash.Length);
        CryptographicOperations.FixedTimeEquals(
            candidate,
            review.Verifier.VerifierHash.Span).Should().BeTrue();
    }

    private static ProtectionAdminOperation CreateOperation(ProtectionActor actor) => new()
    {
        Id = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        Type = ProtectionAdminOperationType.ConnectPurviewTenant,
        Status = ProtectionAdminOperationStatus.AwaitingConfirmation,
        TenantId = new EntraTenantId(actor.TenantId),
        ActorObjectId = actor.ObjectId,
        TargetType = ProtectionAdminTargetType.PurviewTenantConnection,
        TargetIdentifier = actor.TenantId.ToString("D"),
        IdempotencyKey = new ProtectionIdempotencyKey(
            Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")),
        MaximumAttempts = 3,
        CorrelationId = Guid.Parse("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
        CreatedAtUtc = Now,
        UpdatedAtUtc = Now
    };

    private sealed class TestTimeProvider : TimeProvider
    {
        private DateTimeOffset _utcNow;

        public TestTimeProvider(DateTime utcNow)
        {
            _utcNow = new DateTimeOffset(utcNow);
        }

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan duration) => _utcNow += duration;
    }
}
