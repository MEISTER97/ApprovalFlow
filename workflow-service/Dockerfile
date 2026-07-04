# Stage 1: Build the application using the .NET SDK
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy the project file and restore any dependencies
COPY ["workflow-service.csproj", "./"]
RUN dotnet restore "workflow-service.csproj" --disable-parallel

# Copy the rest of the source code and build the app
COPY . .
RUN dotnet build "workflow-service.csproj" -c Release -o /app/build

# Stage 2: Publish the application
FROM build AS publish
RUN dotnet publish "workflow-service.csproj" -c Release -o /app/publish /p:UseAppHost=false

# Stage 3: Build the final runtime image
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
EXPOSE 8080
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "workflow-service.dll"]