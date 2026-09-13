using FluentValidation;
using Gateway.Application.Behaviors;
using Gateway.Application.Protection;
using MediatR;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Gateway.Application;

public static class DependencyInjection
{
    public static IServiceCollection AddApplicationServices(this IServiceCollection services)
    {
        services.TryAddSingleton(TimeProvider.System);
        services.AddMediatR(cfg =>
            cfg.RegisterServicesFromAssembly(typeof(DependencyInjection).Assembly));

        services.AddValidatorsFromAssembly(typeof(DependencyInjection).Assembly);

        services.AddTransient(typeof(IPipelineBehavior<,>), typeof(ValidationBehavior<,>));
        services.AddTransient(typeof(IPipelineBehavior<,>), typeof(LoggingBehavior<,>));
        services.AddSingleton<ProtectionOperationTokenService>();
        services.AddScoped<ProtectionEffectiveFeatureEvaluator>();
        services.AddScoped<AgentPurviewConfigurationService>();
        services.AddScoped<Domain.Interfaces.IPurviewRuntimeTestRunner, PurviewRuntimeTestRunner>();
        services.AddScoped<PurviewRuntimeTestService>(provider => new(
            provider.GetRequiredService<Domain.Interfaces.IPurviewRuntimeTestRepository>(),
            provider.GetRequiredService<Domain.Interfaces.IProtectionAdminOperationRepository>(),
            provider.GetRequiredService<Domain.Interfaces.IAuditEventRepository>(),
            provider.GetRequiredService<Domain.Interfaces.IUnitOfWork>(),
            provider.GetRequiredService<ProtectionOperationTokenService>(),
            provider.GetRequiredService<Domain.Interfaces.IPurviewRuntimeTestRunner>(),
            provider.GetRequiredService<TimeProvider>(),
            provider.GetService<IBootstrapPurviewRuntimeBinding>()));
        services.AddScoped<Domain.Interfaces.IPurviewRuntimeCertificationVerifier>(provider =>
            provider.GetRequiredService<PurviewRuntimeTestService>());

        return services;
    }
}
