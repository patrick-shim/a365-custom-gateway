FROM mcr.microsoft.com/dotnet/runtime:10.0 AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["src/Gateway.Provisioning.Worker/Gateway.Provisioning.Worker.csproj", "src/Gateway.Provisioning.Worker/"]
COPY ["src/Gateway.Application/Gateway.Application.csproj", "src/Gateway.Application/"]
COPY ["src/Gateway.Domain/Gateway.Domain.csproj", "src/Gateway.Domain/"]
COPY ["src/Gateway.Contracts/Gateway.Contracts.csproj", "src/Gateway.Contracts/"]
COPY ["src/Gateway.Infrastructure/Gateway.Infrastructure.csproj", "src/Gateway.Infrastructure/"]
COPY ["src/Gateway.Agent365/Gateway.Agent365.csproj", "src/Gateway.Agent365/"]
COPY ["src/Gateway.Purview/Gateway.Purview.csproj", "src/Gateway.Purview/"]
COPY ["src/Gateway.Observability/Gateway.Observability.csproj", "src/Gateway.Observability/"]
RUN dotnet restore "src/Gateway.Provisioning.Worker/Gateway.Provisioning.Worker.csproj"
COPY . .
WORKDIR "/src/src/Gateway.Provisioning.Worker"
RUN dotnet build "Gateway.Provisioning.Worker.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "Gateway.Provisioning.Worker.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "Gateway.Provisioning.Worker.dll"]
