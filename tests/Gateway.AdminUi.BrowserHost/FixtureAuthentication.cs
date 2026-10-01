using System.Security.Claims;
using System.Text.Encodings.Web;
using Gateway.AdminUi.Authentication;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Gateway.AdminUi.BrowserHost;

internal static class FixtureIdentity
{
    public const string Scheme = "SyntheticBrowserFixture";
    public static readonly Guid TenantId = Guid.Parse("11111111-1111-4111-8111-111111111111");
    public static readonly Guid ActorId = Guid.Parse("22222222-2222-4222-8222-222222222222");
    public static readonly string[] Roles = ["Administrator", "Operator", "Auditor", "SupportReader"];

    public static string NormalizeRole(string role)
    {
        if (string.IsNullOrEmpty(role))
            throw new ArgumentException("A synthetic role is required.");
        var shortName = role.StartsWith("Gateway.", StringComparison.Ordinal) ? role[8..] : role;
        return Roles.Contains(shortName, StringComparer.Ordinal)
            ? $"Gateway.{shortName}"
            : throw new ArgumentException("Only Administrator, Operator, Auditor and SupportReader are fixture roles.");
    }

    public static ClaimsPrincipal Create(string role) => new(new ClaimsIdentity(
    [
        new Claim("name", "Synthetic browser fixture"),
        new Claim("tid", TenantId.ToString("D")),
        new Claim("oid", ActorId.ToString("D")),
        new Claim("roles", NormalizeRole(role))
    ], Scheme, "name", "roles"));
}

internal sealed class FixtureAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    FixtureState state) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync() =>
        Task.FromResult(AuthenticateResult.Success(
            new AuthenticationTicket(FixtureIdentity.Create(state.Role), FixtureIdentity.Scheme)));

    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        Response.StatusCode = StatusCodes.Status401Unauthorized;
        return Task.CompletedTask;
    }

    protected override Task HandleForbiddenAsync(AuthenticationProperties properties)
    {
        Response.StatusCode = StatusCodes.Status403Forbidden;
        return Task.CompletedTask;
    }
}
