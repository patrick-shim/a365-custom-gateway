using FluentValidation;
using Gateway.Application.Behaviors;
using Gateway.Application.Protection;
using MediatR;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.Application;

public static class DependencyInjection
{
    public static IServiceCollection AddApplicationServices(this IServiceCollection services)
    {
        services.AddMediatR(cfg =>
            cfg.RegisterServicesFromAssembly(typeof(DependencyInjection).Assembly));

        services.AddValidatorsFromAssembly(typeof(DependencyInjection).Assembly);

        services.AddTransient(typeof(IPipelineBehavior<,>), typeof(ValidationBehavior<,>));
        services.AddTransient(typeof(IPipelineBehavior<,>), typeof(LoggingBehavior<,>));
        services.AddSingleton<ProtectionOperationTokenService>();
        services.AddScoped<ProtectionEffectiveFeatureEvaluator>();

        return services;
    }
}
