using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Components.Pages;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class AccessDeniedPageTests : BunitContext
{
    public AccessDeniedPageTests()
    {
        Services.AddFluentUIComponents();
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    [Fact]
    public void AccessDeniedPage_IsAuthenticatedRoutableAndRendersExistingGuidance()
    {
        typeof(AccessDeniedPage).GetCustomAttributes(typeof(RouteAttribute), inherit: true)
            .Cast<RouteAttribute>()
            .Should().ContainSingle(attribute => attribute.Template == "/access-denied");
        typeof(AccessDeniedPage).GetCustomAttributes(typeof(AuthorizeAttribute), inherit: true)
            .Should().ContainSingle();

        var cut = Render<AccessDeniedPage>();

        cut.Find(".state-code").TextContent.Should().Be("403");
        cut.Find("h1").TextContent.Should().Be("This area isn't available to your role");
        cut.Find("fluent-anchor").GetAttribute("href").Should().Be("/dashboard");
    }
}
