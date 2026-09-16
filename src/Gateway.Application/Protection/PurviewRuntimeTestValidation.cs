using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Application.Protection;

internal sealed class PurviewRuntimeTestValidationException : Exceptions.DomainException
{
    public PurviewRuntimeTestValidationException(string failureCode)
        : base("The runtime-test request is invalid.", PurviewRuntimeTestFailureCodes.Normalize(failureCode))
    {
        FailureCode = PurviewRuntimeTestFailureCodes.Normalize(failureCode);
    }

    public string FailureCode { get; }
}

internal static class PurviewRuntimeTestValidation
{
    private static readonly UTF8Encoding ExactUtf8 = new(false, true);
    private static readonly byte[] SampleDomain = "A365Gateway.PurviewRuntimeTest.Sample.v1\0"u8.ToArray();
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    // SHA256(domain UTF8 || nonce bytes || uint32 little-endian UTF8 length || exact UTF8 content).
    public static PurviewRuntimeSampleManifest CommitSample(
        string suiteNonce,
        Guid caseId,
        Guid? intendedSensitiveInformationTypeId,
        string content)
    {
        var nonce = ReadNonce(suiteNonce);
        if (caseId == Guid.Empty || intendedSensitiveInformationTypeId == Guid.Empty)
            throw Failure(PurviewRuntimeTestFailureCodes.ManifestInvalid);
        if (content is null || content.Length is < 1 or > PurviewRuntimeTestLimits.MaximumUtf8BytesPerSample)
            throw Failure(PurviewRuntimeTestFailureCodes.SampleBoundsExceeded);

        byte[] bytes;
        try
        {
            var byteCount = ExactUtf8.GetByteCount(content);
            if (byteCount > PurviewRuntimeTestLimits.MaximumUtf8BytesPerSample)
                throw Failure(PurviewRuntimeTestFailureCodes.SampleBoundsExceeded);
            bytes = ExactUtf8.GetBytes(content);
        }
        catch (EncoderFallbackException)
        {
            throw Failure(PurviewRuntimeTestFailureCodes.SampleUtf8Invalid);
        }

        try
        {
            Span<byte> length = stackalloc byte[sizeof(int)];
            BinaryPrimitives.WriteInt32LittleEndian(length, bytes.Length);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            hash.AppendData(SampleDomain);
            hash.AppendData(nonce);
            hash.AppendData(length);
            hash.AppendData(bytes);
            return new(caseId, intendedSensitiveInformationTypeId, FormatHash(hash.GetHashAndReset()), bytes.Length);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public static PurviewRuntimeTestPlan CreatePlan(
        PurviewRuntimeTestContext context,
        ReviewPurviewDlpRuntimeTestRequest request,
        DateTimeOffset utcNow)
    {
        ValidateContext(context, utcNow);
        if (request is null || request.ProfileId != context.Identity.ProfileId ||
            !string.Equals(request.ExpectedRowVersion, context.Versions.ProfileRowVersion, StringComparison.Ordinal) ||
            request.InventoryGenerationId != context.Versions.InventoryGenerationId)
            throw Failure(PurviewRuntimeTestFailureCodes.ContextChanged);
        if (!request.AcknowledgeSyntheticData)
            throw Failure(PurviewRuntimeTestFailureCodes.SyntheticApprovalRequired);
        if (request.Suite is null)
            throw Failure(PurviewRuntimeTestFailureCodes.ManifestInvalid);

        var suite = request.Suite;
        _ = ReadNonce(suite.SuiteNonce);
        if (suite.PositiveSamples.Count != context.SelectedTypes.Length ||
            suite.PositiveSamples.Count is < 1 or > PurviewRuntimeTestLimits.MaximumSelectedTypes ||
            suite.PositiveSamples.Any(sample => sample is null) ||
            suite.NegativeSample is null)
            throw Failure(PurviewRuntimeTestFailureCodes.ManifestInvalid);

        var positives = suite.PositiveSamples.Select(ToManifest).OrderBy(sample => sample.CaseId).ToArray();
        var negative = ToManifest(suite.NegativeSample);
        var all = positives.Append(negative).ToArray();
        if (all.Any(sample => !ValidManifest(sample)) ||
            negative.IntendedSensitiveInformationTypeId is not null ||
            positives.Any(sample => sample.IntendedSensitiveInformationTypeId is null) ||
            all.Select(sample => sample.CaseId).Distinct().Count() != all.Length ||
            all.Select(sample => sample.ContentHash).Distinct(StringComparer.Ordinal).Count() != all.Length ||
            positives.Select(sample => sample.IntendedSensitiveInformationTypeId!.Value).Distinct().Count() != positives.Length ||
            !positives.Select(sample => sample.IntendedSensitiveInformationTypeId!.Value).Order()
                .SequenceEqual(context.SelectedTypes.Select(type => type.Id).Order()))
            throw Failure(PurviewRuntimeTestFailureCodes.ManifestInvalid);

        var batch = request.PositiveCaseIds.Order().ToArray();
        if (batch.Length is < 1 or > PurviewRuntimeTestLimits.MaximumPositiveSamplesPerBatch ||
            batch.Distinct().Count() != batch.Length ||
            batch.Any(id => !positives.Any(sample => sample.CaseId == id)))
            throw Failure(PurviewRuntimeTestFailureCodes.ManifestInvalid);
        if (positives.Where(sample => batch.Contains(sample.CaseId)).Sum(sample => sample.Utf8ByteCount) +
            negative.Utf8ByteCount > PurviewRuntimeTestLimits.MaximumUtf8BytesPerBatch)
            throw Failure(PurviewRuntimeTestFailureCodes.SampleBoundsExceeded);

        var suiteHash = HashMetadata("suite.v1", new
        {
            suite.SuiteNonce,
            positiveSamples = positives,
            negativeSample = negative
        });
        var fingerprint = ConfigurationFingerprint(context);
        return new(
            context, suite.SuiteNonce, positives, negative, batch, suiteHash,
            fingerprint, ReviewedContextFingerprint(context, fingerprint));
    }

    public static void EnsureCurrent(
        PurviewRuntimeTestPlan reviewed,
        PurviewRuntimeTestContext current,
        DateTimeOffset utcNow)
    {
        ValidateContext(current, utcNow);
        var fingerprint = ConfigurationFingerprint(current);
        if (!string.Equals(reviewed.ReviewedContextFingerprint,
                ReviewedContextFingerprint(current, fingerprint), StringComparison.Ordinal))
            throw Failure(PurviewRuntimeTestFailureCodes.ContextChanged);
    }

    public static bool MatchesCertifiedConfiguration(
        PurviewRuntimeTestPlan certified,
        PurviewRuntimeTestContext current,
        DateTimeOffset utcNow)
    {
        ValidateContext(current, utcNow);
        return string.Equals(certified.ConfigurationFingerprint, ConfigurationFingerprint(current), StringComparison.Ordinal);
    }

    public static PurviewRuntimeEphemeralBatch ValidateSamples(
        PurviewRuntimeTestPlan plan,
        IReadOnlyList<PurviewRuntimeTestSampleContentDto> samples)
    {
        var submitted = samples?.ToArray();
        var expected = plan.PositiveSamples.Where(sample => plan.PositiveCaseIds.Contains(sample.CaseId))
            .Append(plan.NegativeSample).ToDictionary(sample => sample.CaseId);
        if (submitted is null || submitted.Length != expected.Count ||
            submitted.Any(sample => sample is null) ||
            submitted.Select(sample => sample.CaseId).Distinct().Count() != submitted.Length ||
            submitted.Any(sample => !expected.ContainsKey(sample.CaseId)))
            throw Failure(PurviewRuntimeTestFailureCodes.SampleMismatch);

        var ephemeral = new List<PurviewRuntimeEphemeralSample>(submitted.Length);
        try
        {
            var totalBytes = 0;
            foreach (var sample in submitted.OrderBy(sample => sample.CaseId))
            {
                var reviewed = expected[sample.CaseId];
                var actual = CommitSample(plan.SuiteNonce, sample.CaseId,
                    reviewed.IntendedSensitiveInformationTypeId, sample.Content);
                if (actual.Utf8ByteCount != reviewed.Utf8ByteCount ||
                    !string.Equals(actual.ContentHash, reviewed.ContentHash, StringComparison.Ordinal))
                    throw Failure(PurviewRuntimeTestFailureCodes.SampleMismatch);
                totalBytes += actual.Utf8ByteCount;
                ephemeral.Add(new(sample.CaseId, sample.Content));
            }

            if (totalBytes > PurviewRuntimeTestLimits.MaximumUtf8BytesPerBatch)
                throw Failure(PurviewRuntimeTestFailureCodes.SampleBoundsExceeded);
            return new(ephemeral, plan.SuiteHash, plan.ReviewedContextFingerprint);
        }
        catch
        {
            foreach (var sample in ephemeral)
                sample.Dispose();
            throw;
        }
    }

    // Validate content even on replay; acceptance hashing never serializes the raw request.
    public static string AcceptedRequestHash(
        PurviewRuntimeTestPlan plan,
        ExecutePurviewDlpRuntimeTestRequest request)
    {
        if (request is null)
            throw Failure(PurviewRuntimeTestFailureCodes.ContextInvalid);
        using var validatedSamples = ValidateSamples(plan, request.Samples);
        if (request.ConfirmationTokenId == Guid.Empty || request.IdempotencyKey == Guid.Empty ||
            request.ConfirmationToken is null || request.ConfirmationToken.Length is < 1 or > 262_144 ||
            !string.Equals(request.ExpectedRowVersion, plan.Context.Versions.ProfileRowVersion, StringComparison.Ordinal) ||
            !string.Equals(validatedSamples.SuiteHash, plan.SuiteHash, StringComparison.Ordinal) ||
            !string.Equals(validatedSamples.ReviewedContextFingerprint, plan.ReviewedContextFingerprint, StringComparison.Ordinal) ||
            !validatedSamples.CaseIds.Order().SequenceEqual(plan.PositiveCaseIds.Append(plan.NegativeSample.CaseId).Order()))
            throw Failure(PurviewRuntimeTestFailureCodes.ContextChanged);

        byte[] tokenBytes;
        try
        {
            tokenBytes = ExactUtf8.GetBytes(request.ConfirmationToken);
        }
        catch (EncoderFallbackException)
        {
            throw Failure(PurviewRuntimeTestFailureCodes.ContextInvalid);
        }

        try
        {
            return HashMetadata("acceptance.v1", new
            {
                request.ConfirmationTokenId,
                confirmationTokenHash = FormatHash(SHA256.HashData(tokenBytes)),
                request.IdempotencyKey,
                request.ExpectedRowVersion,
                plan.ReviewedContextFingerprint,
                plan.SuiteHash,
                positiveCaseIds = plan.PositiveCaseIds.Order().ToArray(),
                negativeCaseId = plan.NegativeSample.CaseId
            });
        }
        finally
        {
            CryptographicOperations.ZeroMemory(tokenBytes);
        }
    }

    public static PurviewRuntimeTestReviewDto ToReviewDto(PurviewRuntimeTestPlan plan) => new(
        plan.Context.Identity.TenantId,
        plan.Context.Identity.ProfileId,
        plan.Context.Identity.AgentRegistrationId,
        plan.Context.Identity.ChildApplicationId,
        plan.Context.Identity.BlueprintApplicationId,
        plan.Context.Identity.ActorObjectId,
        plan.Context.Versions.InventoryGenerationId,
        plan.Context.PolicyMode.ToString(),
        plan.SuiteHash,
        plan.ConfigurationFingerprint,
        plan.ReviewedContextFingerprint,
        plan.Context.SelectedTypes.OrderBy(type => type.Id)
            .Select(type => new PurviewSensitiveInformationTypeSelectionDto(
                plan.Context.Versions.InventoryGenerationId, type.Id, type.ExactName,
                type.MinCount, type.MaxCount, type.MinConfidence, type.MaxConfidence)).ToArray(),
        new(plan.SuiteNonce, plan.PositiveSamples.Select(ToDto).ToArray(), ToDto(plan.NegativeSample)),
        plan.PositiveCaseIds,
        new(PurviewRuntimeTestLimits.MaximumPositiveSamplesPerBatch,
            PurviewRuntimeTestLimits.MaximumUtf8BytesPerSample,
            PurviewRuntimeTestLimits.MaximumUtf8BytesPerBatch,
            (int)PurviewRuntimeTestLimits.ExecutionDeadline.TotalSeconds));

    private static void ValidateContext(PurviewRuntimeTestContext context, DateTimeOffset utcNow)
    {
        if (context is null || context.Identity is null || context.Versions is null)
            throw Failure(PurviewRuntimeTestFailureCodes.ContextInvalid);
        var identity = context.Identity;
        var versions = context.Versions;
        if (utcNow.Offset != TimeSpan.Zero ||
            new[] { identity.TenantId, identity.ActorObjectId, identity.ProfileId, identity.TenantConnectionId,
                identity.BlueprintApplicationId, identity.AgentRegistrationId, identity.ChildApplicationId,
                identity.RuntimePrincipalObjectId, versions.InventoryGenerationId }.Contains(Guid.Empty) ||
            new[] { versions.ProfileRowVersion, versions.ConnectionRowVersion, versions.CapabilityRowVersion,
                versions.InventoryRowVersion, versions.AgentRegistrationRowVersion }.Any(value => !ValidRowVersion(value)) ||
            versions.InventoryExpiresAtUtc.Offset != TimeSpan.Zero ||
            versions.AgentProtectionRevision == Guid.Empty ||
            !Enum.IsDefined(context.PolicyMode) ||
            !BoundedText(context.ProfileDisplayName, 120) ||
            !BoundedText(context.PolicyProviderId, 128) || !BoundedText(context.RuleProviderId, 128) ||
            context.SelectedTypes.Length is < 1 or > PurviewRuntimeTestLimits.MaximumSelectedTypes ||
            context.SelectedTypes.Any(type => type is null || type.Id == Guid.Empty ||
                !BoundedText(type.ExactName, 512) ||
                !PurviewSensitiveInformationTypeThresholds.AreValid(
                    type.MinCount, type.MaxCount, type.MinConfidence, type.MaxConfidence)) ||
            context.SelectedTypes.Select(type => type.Id).Distinct().Count() != context.SelectedTypes.Length ||
            context.Activities.Length is < 1 or > 2 ||
            context.Activities.Any(activity => !Enum.IsDefined(activity)) ||
            context.Activities.Distinct().Count() != context.Activities.Length ||
            !context.Activities.Contains(PurviewPolicyActivity.UploadText) ||
            context.Actions is not [{ Activity: PurviewPolicyActivity.UploadText, Action: PurviewDlpAction.Block }])
            throw Failure(PurviewRuntimeTestFailureCodes.ContextInvalid);
        if (context.PolicyMode == PurviewPolicyMode.Disabled)
            throw Failure(PurviewRuntimeTestFailureCodes.Disabled);
        if (versions.InventoryExpiresAtUtc <= utcNow)
            throw Failure(PurviewRuntimeTestFailureCodes.InventoryExpired);
    }

    private static string ConfigurationFingerprint(PurviewRuntimeTestContext context) =>
        HashMetadata("configuration.v1", new
        {
            context.Identity,
            context.Versions.ConnectionRowVersion,
            context.Versions.CapabilityRowVersion,
            context.Versions.InventoryGenerationId,
            context.Versions.InventoryRowVersion,
            context.Versions.InventoryExpiresAtUtc,
            // Activity/telemetry writes must not revoke a protection certification.
            context.Versions.AgentProtectionRevision,
            policyMode = context.PolicyMode.ToString(),
            context.ProfileDisplayName,
            context.PolicyProviderId,
            context.RuleProviderId,
            selectedTypes = context.SelectedTypes.OrderBy(type => type.Id).ToArray(),
            activities = context.Activities.Order().Select(value => value.ToString()).ToArray(),
            actions = context.Actions.OrderBy(action => action.Activity).ThenBy(action => action.Action)
                .Select(action => new { activity = action.Activity.ToString(), action = action.Action.ToString() }).ToArray()
        });

    private static string ReviewedContextFingerprint(PurviewRuntimeTestContext context, string configurationFingerprint) =>
        HashMetadata("review-context.v1", new { configurationFingerprint, context.Versions.ProfileRowVersion });

    private static string HashMetadata<T>(string purpose, T value)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            domain = $"A365Gateway.PurviewRuntimeTest.{purpose}",
            value
        }, JsonOptions);
        return FormatHash(SHA256.HashData(bytes));
    }

    private static bool ValidManifest(PurviewRuntimeSampleManifest sample) =>
        sample.CaseId != Guid.Empty &&
        sample.Utf8ByteCount is >= 1 and <= PurviewRuntimeTestLimits.MaximumUtf8BytesPerSample &&
        sample.ContentHash is { Length: 71 } &&
        sample.ContentHash.StartsWith("sha256:", StringComparison.Ordinal) &&
        LowerHex(sample.ContentHash.AsSpan(7));

    private static byte[] ReadNonce(string value)
    {
        if (value is not { Length: PurviewRuntimeTestLimits.SuiteNonceBytes * 2 } || !LowerHex(value.AsSpan()))
            throw Failure(PurviewRuntimeTestFailureCodes.ManifestInvalid);
        return Convert.FromHexString(value);
    }

    private static bool LowerHex(ReadOnlySpan<char> value)
    {
        foreach (var character in value)
            if (character is not (>= '0' and <= '9' or >= 'a' and <= 'f'))
                return false;
        return true;
    }

    private static bool ValidRowVersion(string value)
    {
        if (value is not { Length: 12 })
            return false;
        Span<byte> decoded = stackalloc byte[8];
        return Convert.TryFromBase64String(value, decoded, out var written) &&
            written == 8 && string.Equals(Convert.ToBase64String(decoded), value, StringComparison.Ordinal);
    }

    private static bool BoundedText(string value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximumLength || value.Any(char.IsControl))
            return false;
        try
        {
            _ = ExactUtf8.GetByteCount(value);
            return true;
        }
        catch (EncoderFallbackException)
        {
            return false;
        }
    }

    private static string FormatHash(byte[] hash) => $"sha256:{Convert.ToHexString(hash).ToLowerInvariant()}";
    private static PurviewRuntimeSampleManifest ToManifest(PurviewRuntimeTestSampleManifestDto dto) =>
        new(dto.CaseId, dto.IntendedSensitiveInformationTypeId, dto.ContentHash, dto.Utf8ByteCount);
    private static PurviewRuntimeTestSampleManifestDto ToDto(PurviewRuntimeSampleManifest value) =>
        new(value.CaseId, value.IntendedSensitiveInformationTypeId, value.ContentHash, value.Utf8ByteCount);
    private static PurviewRuntimeTestValidationException Failure(string code) => new(code);
}
