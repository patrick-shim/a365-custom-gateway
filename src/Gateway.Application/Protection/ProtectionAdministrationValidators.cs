using FluentValidation;

namespace Gateway.Application.Protection;

public sealed class ReviewPurviewTenantConnectionCommandValidator
    : AbstractValidator<ReviewPurviewTenantConnectionCommand>
{
    public ReviewPurviewTenantConnectionCommandValidator()
    {
        RuleFor(command => command.Request.TenantId).NotEmpty();
        RuleFor(command => command.Request.ExpectedRowVersion)
            .Must(ProtectionValidatorRules.BeExpectedRowVersion);
    }

    public sealed class ReviewPurviewTenantConnectionCompletionCommandValidator
        : AbstractValidator<ReviewPurviewTenantConnectionCompletionCommand>
    {
        public ReviewPurviewTenantConnectionCompletionCommandValidator()
        {
            RuleFor(command => command.OperationId).NotEmpty();
            RuleFor(command => command.Request.OperationId).NotEmpty();
            RuleFor(command => command.Request.InventoryGenerationId).NotEmpty();
            RuleFor(command => command.Request.EvidenceDigest)
                .Matches("^sha256:[0-9a-f]{64}$");
            RuleFor(command => command.Request.Evidence).NotNull();
            RuleFor(command => command.Request.ExpectedRowVersion)
                .Must(ProtectionValidatorRules.BeExpectedRowVersion);
        }
    }
}

public sealed class ReviewPurviewKnowYourDataCommandValidator
    : AbstractValidator<ReviewPurviewKnowYourDataCommand>
{
    public ReviewPurviewKnowYourDataCommandValidator()
    {
        RuleFor(command => command.Request.TenantConnectionId).NotEmpty();
        RuleFor(command => command.Request.SensitiveInformationType).NotNull();
        When(
            command => command.Request.SensitiveInformationType is not null,
            () =>
            {
                RuleFor(command =>
                        command.Request.SensitiveInformationType.InventoryGenerationId)
                    .NotEmpty();
                RuleFor(command =>
                        command.Request.SensitiveInformationType.SensitiveInformationTypeId)
                    .NotEmpty();
                RuleFor(command =>
                        command.Request.SensitiveInformationType.ExactName)
                    .NotEmpty()
                    .MaximumLength(255);
            });
        RuleFor(command => command.Request.Mode).NotEmpty().MaximumLength(32);
        RuleFor(command => command.Request.Activities)
            .NotNull()
            .Must(values => values.Count is >= 1 and <= 2);
        RuleFor(command => command.Request.ExpectedRowVersion)
            .Must(ProtectionValidatorRules.BeExpectedRowVersion);
    }
}

public sealed class ReviewPurviewDlpProfileCommandValidator
    : AbstractValidator<ReviewPurviewDlpProfileCommand>
{
    public ReviewPurviewDlpProfileCommandValidator()
    {
        RuleFor(command => command.Request.TenantConnectionId).NotEmpty();
        RuleFor(command => command.Request.BlueprintApplicationId).NotEmpty();
        RuleFor(command => command.Request.DisplayName)
            .NotEmpty()
            .MaximumLength(120);
        RuleFor(command => command.Request.SensitiveInformationType).NotNull();
        When(
            command => command.Request.SensitiveInformationType is not null,
            () =>
            {
                RuleFor(command =>
                        command.Request.SensitiveInformationType.InventoryGenerationId)
                    .NotEmpty();
                RuleFor(command =>
                        command.Request.SensitiveInformationType.SensitiveInformationTypeId)
                    .NotEmpty();
                RuleFor(command =>
                        command.Request.SensitiveInformationType.ExactName)
                    .NotEmpty()
                    .MaximumLength(255);
            });
        RuleFor(command => command.Request.Mode).NotEmpty().MaximumLength(32);
        RuleFor(command => command.Request.Activities)
            .NotNull()
            .Must(values => values.Count is >= 1 and <= 2);
        RuleFor(command => command.Request.Actions)
            .NotNull()
            .Must(values => values.Count is >= 1 and <= 4);
        RuleFor(command => command.Request.ExpectedRowVersion)
            .Must(ProtectionValidatorRules.BeExpectedRowVersion);
    }

    public sealed class ReviewReconcilePurviewDlpProfileCommandValidator
        : AbstractValidator<ReviewReconcilePurviewDlpProfileCommand>
    {
        public ReviewReconcilePurviewDlpProfileCommandValidator()
        {
            RuleFor(command => command.ProfileId).NotEmpty();
            RuleFor(command => command.Request.ProfileId).NotEmpty();
            RuleFor(command => command.Request.ExpectedRowVersion)
                .Must(ProtectionValidatorRules.BeExpectedRowVersion);
        }
    }

    public sealed class ReviewValidatePurviewDlpRuntimeCommandValidator
        : AbstractValidator<ReviewValidatePurviewDlpRuntimeCommand>
    {
        public ReviewValidatePurviewDlpRuntimeCommandValidator()
        {
            RuleFor(command => command.ProfileId).NotEmpty();
            RuleFor(command => command.Request.ProfileId).NotEmpty();
            RuleFor(command => command.Request.ExpectedRowVersion)
                .Must(ProtectionValidatorRules.BeExpectedRowVersion);
        }
    }
}

public sealed class ConfirmProtectionOperationReviewCommandValidator
    : AbstractValidator<ConfirmProtectionOperationReviewCommand>
{
    public ConfirmProtectionOperationReviewCommandValidator()
    {
        RuleFor(command => command.Request.ReviewTokenId).NotEmpty();
        RuleFor(command => command.Request.ReviewToken)
            .NotEmpty()
            .MaximumLength(16_384);
    }
}

public sealed class StartPurviewTenantConnectionCommandValidator
    : AbstractValidator<StartPurviewTenantConnectionCommand>
{
    public StartPurviewTenantConnectionCommandValidator() =>
        ProtectionValidatorRules.AddMutationRules(
            this,
            command => command.Request.ConfirmationTokenId,
            command => command.Request.ConfirmationToken,
            command => command.Request.IdempotencyKey,
            command => command.Request.ExpectedRowVersion);
}

public sealed class CompletePurviewTenantConnectionCommandValidator
    : AbstractValidator<CompletePurviewTenantConnectionCommand>
{
    public CompletePurviewTenantConnectionCommandValidator()
    {
        RuleFor(command => command.OperationId).NotEmpty();
        RuleFor(command => command.Request.Evidence).NotNull();
        ProtectionValidatorRules.AddMutationRules(
            this,
            command => command.Request.ConfirmationTokenId,
            command => command.Request.ConfirmationToken,
            command => command.Request.IdempotencyKey,
            command => command.Request.ExpectedRowVersion);
    }
}

public sealed class StartPurviewKnowYourDataCommandValidator
    : AbstractValidator<StartPurviewKnowYourDataCommand>
{
    public StartPurviewKnowYourDataCommandValidator() =>
        ProtectionValidatorRules.AddMutationRules(
            this,
            command => command.Request.ConfirmationTokenId,
            command => command.Request.ConfirmationToken,
            command => command.Request.IdempotencyKey,
            command => command.Request.ExpectedRowVersion);
}

public sealed class StartPurviewDlpProfileCommandValidator
    : AbstractValidator<StartPurviewDlpProfileCommand>
{
    public StartPurviewDlpProfileCommandValidator() =>
        ProtectionValidatorRules.AddMutationRules(
            this,
            command => command.Request.ConfirmationTokenId,
            command => command.Request.ConfirmationToken,
            command => command.Request.IdempotencyKey,
            command => command.Request.ExpectedRowVersion);
}

public sealed class ReconcilePurviewDlpProfileCommandValidator
    : AbstractValidator<ReconcilePurviewDlpProfileCommand>
{
    public ReconcilePurviewDlpProfileCommandValidator()
    {
        RuleFor(command => command.ProfileId).NotEmpty();
        ProtectionValidatorRules.AddMutationRules(
            this,
            command => command.Request.ConfirmationTokenId,
            command => command.Request.ConfirmationToken,
            command => command.Request.IdempotencyKey,
            command => command.Request.ExpectedRowVersion);
    }
}

public sealed class ValidatePurviewDlpProfileRuntimeCommandValidator
    : AbstractValidator<ValidatePurviewDlpProfileRuntimeCommand>
{
    public ValidatePurviewDlpProfileRuntimeCommandValidator()
    {
        RuleFor(command => command.ProfileId).NotEmpty();
        ProtectionValidatorRules.AddMutationRules(
            this,
            command => command.Request.ConfirmationTokenId,
            command => command.Request.ConfirmationToken,
            command => command.Request.IdempotencyKey,
            command => command.Request.ExpectedRowVersion);
    }
}

internal static class ProtectionValidatorRules
{
    public static void AddMutationRules<T>(
        AbstractValidator<T> validator,
        System.Linq.Expressions.Expression<Func<T, Guid>> tokenId,
        System.Linq.Expressions.Expression<Func<T, string>> token,
        System.Linq.Expressions.Expression<Func<T, Guid>> idempotencyKey,
        System.Linq.Expressions.Expression<Func<T, string>> expectedRowVersion)
    {
        validator.RuleFor(tokenId).NotEmpty();
        validator.RuleFor(token).NotEmpty().MaximumLength(16_384);
        validator.RuleFor(idempotencyKey)
            .Must(value =>
            {
                if (value == Guid.Empty)
                    return false;
                var canonical = value.ToString("D");
                return canonical[14] == '4' &&
                    canonical[19] is '8' or '9' or 'a' or 'b';
            })
            .WithMessage("IdempotencyKey must be a canonical UUIDv4 value.");
        validator.RuleFor(expectedRowVersion).Must(BeExpectedRowVersion);
    }

    public static bool BeExpectedRowVersion(string value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length > 128 ||
            value.Contains('\r') ||
            value.Contains('\n'))
        {
            return false;
        }

        if (string.Equals(value, "*", StringComparison.Ordinal))
            return true;
        try
        {
            var decoded = Convert.FromBase64String(value);
            return decoded.Length == 8 &&
                string.Equals(
                    Convert.ToBase64String(decoded),
                    value,
                    StringComparison.Ordinal);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
