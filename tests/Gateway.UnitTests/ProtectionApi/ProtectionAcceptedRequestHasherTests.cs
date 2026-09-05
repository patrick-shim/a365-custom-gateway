using FluentAssertions;
using Gateway.Application.Protection;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class ProtectionAcceptedRequestHasherTests
{
    [Fact]
    public void ConnectionEvidenceHashIsCanonicalAndPayloadSensitive()
    {
        var tenantId = Guid.NewGuid();
        var actorId = Guid.NewGuid();
        var tokenId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        var key = Guid.NewGuid();
        var observedAtUtc = DateTime.UtcNow;
        var first = CreateRequest(
            operationId,
            tokenId,
            key,
            tenantId,
            actorId,
            observedAtUtc,
            [
                new PurviewSensitiveInformationTypeDto(
                    Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                    "Zulu",
                    "Microsoft"),
                new PurviewSensitiveInformationTypeDto(
                    Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                    "Alpha",
                    "Microsoft")
            ]);
        var reordered = first with
        {
            Evidence = first.Evidence with
            {
                SensitiveInformationTypes =
                    first.Evidence.SensitiveInformationTypes.Reverse().ToArray()
            }
        };
        var changed = first with
        {
            Evidence = first.Evidence with
            {
                SensitiveInformationTypes =
                [
                    first.Evidence.SensitiveInformationTypes[0] with
                    {
                        ExactName = "Changed"
                    },
                    first.Evidence.SensitiveInformationTypes[1]
                ]
            }
        };

        ProtectionAcceptedRequestHasher.Compute(operationId, first)
            .Should().Be(
                ProtectionAcceptedRequestHasher.Compute(
                    operationId,
                    reordered));
        ProtectionAcceptedRequestHasher.Compute(operationId, changed)
            .Should().NotBe(
                ProtectionAcceptedRequestHasher.Compute(
                    operationId,
                    first));
    }

    private static CompletePurviewTenantConnectionOperationRequest CreateRequest(
        Guid operationId,
        Guid tokenId,
        Guid key,
        Guid tenantId,
        Guid actorId,
        DateTimeOffset observedAtUtc,
        IReadOnlyList<PurviewSensitiveInformationTypeDto> items)
    {
        var generationId = Guid.NewGuid();
        var evidence = new PurviewTenantConnectionEvidenceDto(
            tenantId,
            actorId,
            [
                "DlpPolicy.ReadWrite",
                "DlpRule.ReadWrite",
                "KnowYourData.ReadWrite",
                "SensitiveInformationTypes.Read"
            ],
            observedAtUtc,
            observedAtUtc.AddMinutes(10),
            items);
        return new(
            tokenId,
            "opaque-confirmation",
            key,
            "AQIDBAUGBwg=",
            generationId,
            PurviewTenantConnectionEvidenceDigest.Compute(
                operationId,
                generationId,
                evidence),
            evidence);
    }
}
