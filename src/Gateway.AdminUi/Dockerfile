ARG DOTNET_SDK_VERSION=10.0.400
ARG ASPNET_RUNTIME_VERSION=10.0.11

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_VERSION} AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src

COPY ["global.json", "./"]
COPY ["nuget.config", "./"]
COPY ["src/Gateway.AdminUi/Gateway.AdminUi.csproj", "src/Gateway.AdminUi/"]
COPY ["src/Gateway.Contracts/Gateway.Contracts.csproj", "src/Gateway.Contracts/"]
RUN dotnet restore "src/Gateway.AdminUi/Gateway.AdminUi.csproj" --configfile nuget.config

COPY ["src/Gateway.AdminUi/", "src/Gateway.AdminUi/"]
COPY ["src/Gateway.Contracts/", "src/Gateway.Contracts/"]
WORKDIR "/src/src/Gateway.AdminUi"
RUN dotnet publish "Gateway.AdminUi.csproj" \
    --configuration "$BUILD_CONFIGURATION" \
    --no-restore \
    --output /app/publish \
    /p:UseAppHost=false
RUN test -s /app/publish/wwwroot/_framework/blazor.web.js \
    && test -s /app/publish/Gateway.AdminUi.staticwebassets.endpoints.json

FROM mcr.microsoft.com/dotnet/aspnet:${ASPNET_RUNTIME_VERSION} AS final
WORKDIR /app
EXPOSE 8080

ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_EnableDiagnostics=0

COPY --from=build /app/publish .
USER $APP_UID

ENTRYPOINT ["dotnet", "Gateway.AdminUi.dll"]
