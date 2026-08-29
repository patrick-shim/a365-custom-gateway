FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 8080

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["global.json", "./"]
COPY ["nuget.config", "./"]
COPY ["src/Gateway.Api/Gateway.Api.csproj", "src/Gateway.Api/"]
COPY ["src/Gateway.Application/Gateway.Application.csproj", "src/Gateway.Application/"]
COPY ["src/Gateway.Domain/Gateway.Domain.csproj", "src/Gateway.Domain/"]
COPY ["src/Gateway.Contracts/Gateway.Contracts.csproj", "src/Gateway.Contracts/"]
COPY ["src/Gateway.Infrastructure/Gateway.Infrastructure.csproj", "src/Gateway.Infrastructure/"]
COPY ["src/Gateway.Agent365/Gateway.Agent365.csproj", "src/Gateway.Agent365/"]
COPY ["src/Gateway.Purview/Gateway.Purview.csproj", "src/Gateway.Purview/"]
COPY ["src/Gateway.ContentSafety/Gateway.ContentSafety.csproj", "src/Gateway.ContentSafety/"]
COPY ["src/Gateway.Observability/Gateway.Observability.csproj", "src/Gateway.Observability/"]
RUN dotnet restore "src/Gateway.Api/Gateway.Api.csproj" --configfile nuget.config
COPY . .
WORKDIR "/src/src/Gateway.Api"
RUN dotnet build "Gateway.Api.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "Gateway.Api.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_EnableDiagnostics=0
USER $APP_UID
ENTRYPOINT ["dotnet", "Gateway.Api.dll"]
