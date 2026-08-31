FROM mcr.microsoft.com/dotnet/runtime:10.0 AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["global.json", "./"]
COPY ["nuget.config", "./"]
COPY ["tools/Gateway.LiveVerification/Gateway.LiveVerification.csproj", "tools/Gateway.LiveVerification/"]
RUN dotnet restore "tools/Gateway.LiveVerification/Gateway.LiveVerification.csproj" --configfile nuget.config
COPY . .
WORKDIR "/src/tools/Gateway.LiveVerification"
RUN dotnet publish "Gateway.LiveVerification.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENV DOTNET_EnableDiagnostics=0
USER $APP_UID
ENTRYPOINT ["dotnet", "Gateway.LiveVerification.dll"]
