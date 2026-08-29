namespace Gateway.Setup.Services;

internal static class SetupServiceCollectionExtensions
{
    public static IServiceCollection AddSetupWorkflow(this IServiceCollection services)
    {
        services.AddSingleton<IProjectNameGenerator, ProjectNameGenerator>();
        services.AddSingleton<SetupWizardState>();
        services.AddSingleton<IAtomicFileWriter, AtomicFileWriter>();
        services.AddSingleton<IBootstrapConfigWriter, BootstrapConfigWriter>();
        services.AddSingleton<IBootstrapConfigLoader, BootstrapConfigLoader>();
        services.AddSingleton<IAzureAccountDiscovery, AzureAccountDiscovery>();
        services.AddSingleton<IBootstrapCommandFactory, BootstrapCommandFactory>();
        services.AddSingleton<IBootstrapProcessRunner, BootstrapProcessRunner>();
        services.AddSingleton<BootstrapExecutionCoordinator>();
        return services;
    }
}
