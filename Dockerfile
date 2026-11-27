# ------------------------------------------------------------------
# One image = Angular UI + ASP.NET Core API (.NET 10)
#   Stage 1: build Angular       (node)
#   Stage 2: build + publish API (dotnet SDK)
#   Stage 3: small runtime image (aspnet), runs as non-root on port 8080
# Build:  docker build -t portfolio-rag:local .
# Run:    docker run -p 8080:8080 --env-file .env portfolio-rag:local
# ------------------------------------------------------------------

# ---------- Stage 1: Angular ----------
FROM node:22-alpine AS ui
WORKDIR /ui
COPY src/portfolio-ui/package*.json ./
RUN npm ci                                   # cached layer: only reruns when package files change
COPY src/portfolio-ui/ ./
RUN npx ng build --configuration production

# ---------- Stage 2: .NET build ----------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/PortfolioRag.Api/PortfolioRag.Api.csproj PortfolioRag.Api/
RUN dotnet restore PortfolioRag.Api/PortfolioRag.Api.csproj    # cached layer: only reruns when the csproj changes
COPY src/PortfolioRag.Api/ PortfolioRag.Api/
RUN dotnet publish PortfolioRag.Api/PortfolioRag.Api.csproj -c Release -o /app --no-restore /p:UseAppHost=false

# ---------- Stage 3: runtime ----------
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
# fontconfig + fonts: QuestPDF (Skia) draws SVG chart text with system fonts (Liberation = Arial-compatible sans);
# tzdata: America/New_York dates in the PDF
RUN apt-get update \
 && apt-get install -y --no-install-recommends libfontconfig1 tzdata fonts-dejavu-core fonts-liberation \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app ./
COPY --from=ui /ui/dist/portfolio-ui/browser ./wwwroot
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false
EXPOSE 8080
# The aspnet image ships a non-root user; never run containers as root
USER $APP_UID
ENTRYPOINT ["dotnet", "PortfolioRag.Api.dll"]
