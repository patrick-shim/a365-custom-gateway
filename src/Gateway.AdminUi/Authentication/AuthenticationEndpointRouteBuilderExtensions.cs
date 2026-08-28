using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;

namespace Gateway.AdminUi.Authentication;

public static class AuthenticationEndpointRouteBuilderExtensions
{
    public static IEndpointRouteBuilder MapGatewayAuthenticationEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapGet("/authentication/login", (string? returnUrl) =>
            Results.Challenge(
                new AuthenticationProperties
                {
                    RedirectUri = AuthenticationReturnUrl.Normalize(returnUrl)
                },
                [OpenIdConnectDefaults.AuthenticationScheme]))
            .AllowAnonymous();

        endpoints.MapPost(
                "/authentication/logout",
                async (HttpContext context, IAntiforgery antiforgery, string? returnUrl) =>
                {
                    await antiforgery.ValidateRequestAsync(context);

                    return Results.SignOut(
                        new AuthenticationProperties
                        {
                            RedirectUri = AuthenticationReturnUrl.Normalize(returnUrl)
                        },
                        [
                            CookieAuthenticationDefaults.AuthenticationScheme,
                            OpenIdConnectDefaults.AuthenticationScheme
                        ]);
                })
            .RequireAuthorization();

        return endpoints;
    }
}
