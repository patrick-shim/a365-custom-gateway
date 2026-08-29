FROM mcr.microsoft.com/dotnet/runtime:10.0 AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["global.json", "./"]
COPY ["nuget.config", "./"]
COPY ["tools/Gateway.LiveCanary/Gateway.LiveCanary.csproj", "tools/Gateway.LiveCanary/"]
RUN dotnet restore "tools/Gateway.LiveCanary/Gateway.LiveCanary.csproj" --configfile nuget.config
COPY . .
WORKDIR "/src/tools/Gateway.LiveCanary"
RUN dotnet publish "Gateway.LiveCanary.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENV DOTNET_EnableDiagnostics=0
USER $APP_UID
ENTRYPOINT ["dotnet", "Gateway.LiveCanary.dll"]
