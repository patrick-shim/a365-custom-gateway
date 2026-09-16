using System.Text.Json;

namespace Gateway.LiveVerification;

internal static class ControlTokenValidator
{
    // This is a fail-fast authority check before any request leaves the process.
    // The Gateway API remains responsible for cryptographic token validation.
    internal static void Validate(
        string token,
        Guid apiApplicationClientId,
        Guid tenantId,
        bool requireDelegatedUser,
        Guid expectedUserObjectId,
        Guid? expectedClientApplicationId)
    {
        var segments = token.Split('.');
        if (segments.Length != 3 || segments[1].Length is 0 or > 32_768)
            throw new InvalidOperationException("The control-plane access token has an invalid bounded JWT shape.");

        var payloadBytes = DecodeBase64Url(segments[1]);
        try
        {
            using var payload = JsonDocument.Parse(payloadBytes);
            var root = payload.RootElement;
            var audience = ReadRequiredStringClaim(root, "aud");
            if (!Guid.TryParse(audience, out var parsedAudience)
                || parsedAudience != apiApplicationClientId)
                throw new InvalidOperationException("The control-plane access token has the wrong API audience.");
            var tenant = ReadRequiredStringClaim(root, "tid");
            if (!Guid.TryParse(tenant, out var parsedTenant) || parsedTenant != tenantId)
                throw new InvalidOperationException("The control-plane access token has the wrong tenant.");

            if (!root.TryGetProperty("roles", out var roles)
                || roles.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException(
                    "The control-plane access token does not contain Gateway.Administrator.");
            var roleValues = roles.EnumerateArray().ToArray();
            if (roleValues.Length != 1
                || roleValues[0].ValueKind != JsonValueKind.String
                || !string.Equals(
                    roleValues[0].GetString(),
                    "Gateway.Administrator",
                    StringComparison.Ordinal))
                throw new InvalidOperationException(
                    "The control-plane access token does not contain only Gateway.Administrator.");

            if (requireDelegatedUser)
            {
                if (expectedClientApplicationId is null
                    || expectedClientApplicationId == Guid.Empty)
                    throw new InvalidOperationException(
                        "The interactive control-plane token is missing its expected client binding.");
                var authorizedParty = ReadRequiredStringClaim(root, "azp");
                if (!Guid.TryParse(authorizedParty, out var parsedAuthorizedParty)
                    || parsedAuthorizedParty != expectedClientApplicationId)
                    throw new InvalidOperationException(
                        "The interactive control-plane token is not bound to the expected client application.");
                var userObjectId = ReadRequiredStringClaim(root, "oid");
                if (!Guid.TryParse(userObjectId, out var parsedUserObjectId)
                    || parsedUserObjectId != expectedUserObjectId)
                    throw new InvalidOperationException(
                        "The interactive control-plane token is not bound to the expected tenant user.");
                var scopes = ReadRequiredStringClaim(root, "scp").Split(
                    ' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (scopes.Length != 1
                    || !string.Equals(scopes[0], "access_as_user", StringComparison.Ordinal))
                    throw new InvalidOperationException(
                        "The interactive control-plane token does not contain only access_as_user.");
            }
            else if (root.TryGetProperty("scp", out _))
            {
                throw new InvalidOperationException(
                    "The managed-identity control-plane token unexpectedly contains delegated scopes.");
            }
        }
        catch (JsonException)
        {
            throw new InvalidOperationException(
                "The control-plane access token contains an invalid JSON claim set.");
        }
        finally
        {
            Array.Clear(payloadBytes);
        }
    }

    private static byte[] DecodeBase64Url(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized += (normalized.Length % 4) switch
        {
            0 => string.Empty,
            2 => "==",
            3 => "=",
            _ => throw new InvalidOperationException(
                "The control-plane access token has invalid base64url padding.")
        };
        try
        {
            return Convert.FromBase64String(normalized);
        }
        catch (FormatException)
        {
            throw new InvalidOperationException(
                "The control-plane access token has an invalid base64url payload.");
        }
    }

    private static string ReadRequiredStringClaim(JsonElement payload, string name)
    {
        if (!payload.TryGetProperty(name, out var claim)
            || claim.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(claim.GetString()))
            throw new InvalidOperationException(
                "The control-plane access token is missing a required bounded claim.");
        return claim.GetString()!;
    }
}
