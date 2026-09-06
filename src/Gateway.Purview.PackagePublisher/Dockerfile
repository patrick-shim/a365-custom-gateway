FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY src/Gateway.Purview.PackagePublisher/Gateway.Purview.PackagePublisher.csproj src/Gateway.Purview.PackagePublisher/
RUN dotnet restore src/Gateway.Purview.PackagePublisher/Gateway.Purview.PackagePublisher.csproj
COPY src/Gateway.Purview.PackagePublisher/ src/Gateway.Purview.PackagePublisher/
RUN dotnet publish src/Gateway.Purview.PackagePublisher/Gateway.Purview.PackagePublisher.csproj -c Release --no-restore -o /out

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /out/ ./
# Orchestration supplies only the independently hashed, reviewed public package.
# This build context must never contain runtime configuration or credentials.
COPY payload/executor.zip /app/payload/executor.zip
USER $APP_UID
ENTRYPOINT ["dotnet", "Gateway.Purview.PackagePublisher.dll"]
