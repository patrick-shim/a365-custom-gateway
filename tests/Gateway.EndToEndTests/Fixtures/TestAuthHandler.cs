using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.EndToEndTests.Fixtures;

public class TestAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public const string SchemeName = "TestScheme";
    public const string DefaultObjectId = "test-oid-001";
    public const string DefaultClientId = "test-client-001";

    public static IList<Claim> Claims { get; set; } = new List<Claim>();
    public static string? DefaultRole { get; set; } = "Gateway.Administrator";
    public static bool ShouldAuthenticate { get; set; } = true;

    public TestAuthHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder) : base(options, logger, encoder) { }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!ShouldAuthenticate)
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var claims = new List<Claim>(Claims);

        if (!claims.Any(c => c.Type == "http://schemas.microsoft.com/identity/claims/objectidentifier" || c.Type == "oid"))
            claims.Add(new Claim("http://schemas.microsoft.com/identity/claims/objectidentifier", DefaultObjectId));

        if (!claims.Any(c => c.Type == "appid" || c.Type == "azp"))
            claims.Add(new Claim("appid", DefaultClientId));

        if (DefaultRole is not null && !claims.Any(c => c.Type == ClaimTypes.Role))
            claims.Add(new Claim(ClaimTypes.Role, DefaultRole));

        var identity = new ClaimsIdentity(claims, SchemeName);
        var principal = new ClaimsPrincipal(identity);
        var ticket = new AuthenticationTicket(principal, SchemeName);

        return Task.FromResult(AuthenticateResult.Success(ticket));
    }

    public static void Reset()
    {
        Claims = new List<Claim>();
        DefaultRole = "Gateway.Administrator";
        ShouldAuthenticate = true;
    }
}
