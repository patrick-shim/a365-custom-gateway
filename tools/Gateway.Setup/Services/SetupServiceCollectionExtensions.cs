namespace Gateway.Setup.Services;

internal static class SetupServiceCollectionExtensions
{
    public static IServiceCollection AddSetupWorkflow(this IServiceCollection services)
    {
        services.AddSingleton<IProjectNameGenerator, ProjectNameGenerator>();
        services.AddScoped<SetupWizardState>();
        services.AddSingleton<IAtomicFileWriter, AtomicFileWriter>();
        services.AddSingleton<IBootstrapConfigWriter, BootstrapConfigWriter>();
        services.AddSingleton<IBootstrapConfigLoader, BootstrapConfigLoader>();
        services.AddSingleton<IAzureCliExecutableResolver, AzureCliExecutableResolver>();
        services.AddSingleton<IAzureCliRunner, AzureCliRunner>();
        services.AddSingleton<IAzureAccountDiscovery>(provider =>
            new AzureAccountDiscovery(provider.GetRequiredService<IAzureCliRunner>()));
        services.AddSingleton<IPurviewPowerShellExecutableResolver, PurviewPowerShellExecutableResolver>();
        services.AddSingleton<IPurviewSensitiveInformationTypePlatformSupport,
            PurviewSensitiveInformationTypePlatformSupport>();
        services.AddSingleton<IPurviewSensitiveInformationTypeRunner, PurviewSensitiveInformationTypeRunner>();
        services.AddSingleton<IPurviewSensitiveInformationTypeDiscovery, PurviewSensitiveInformationTypeDiscovery>();
        services.AddSingleton<IBootstrapCommandFactory, BootstrapCommandFactory>();
        services.AddSingleton<IBootstrapProcessRunner, BootstrapProcessRunner>();
        services.AddSingleton<BootstrapExecutionCoordinator>();
        services.AddSingleton<BootstrapPlanPreparationCoordinator>();
        return services;
    }
}
