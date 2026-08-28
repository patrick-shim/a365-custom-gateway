FROM mcr.microsoft.com/dotnet/runtime:10.0 AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["global.json", "./"]
COPY ["nuget.config", "./"]
COPY ["tools/Gateway.DatabaseMigrator/Gateway.DatabaseMigrator.csproj", "tools/Gateway.DatabaseMigrator/"]
RUN dotnet restore "tools/Gateway.DatabaseMigrator/Gateway.DatabaseMigrator.csproj" --configfile nuget.config
COPY . .
WORKDIR "/src/tools/Gateway.DatabaseMigrator"
RUN dotnet publish "Gateway.DatabaseMigrator.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
COPY --from=build /src/deploy/sql /app/deploy/sql
ENV DOTNET_EnableDiagnostics=0
USER $APP_UID
ENTRYPOINT ["dotnet", "Gateway.DatabaseMigrator.dll"]
CMD ["--server", "sql-a365gw-dev.database.windows.net", "--database", "GatewayDb", "--phase", "verify", "--repeat", "1", "--repository-root", "/app", "--evidence-stdout", "true"]
