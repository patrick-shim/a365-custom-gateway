using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.Provisioning.Worker;

public static class DependencyInjection
{
    public static IServiceCollection AddProtectionAdministrationWorker(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.Configure<ProtectionAdminWorkerOptions>(
            configuration.GetSection(ProtectionAdminWorkerOptions.SectionName));
        services.AddSingleton<
            IPurviewConnectionVerificationProvider,
            PowerShellPurviewConnectionVerificationProvider>();
        services.AddScoped<IPurviewRuntimeReadinessValidator, PurviewRuntimeReadinessValidator>();
        services.AddScoped<ProtectionAdminMessageHandler>();
        services.AddHostedService<ProtectionAdminWorkerService>();
        return services;
    }
}
