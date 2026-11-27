using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using PortfolioRag.Api.Data;
using PortfolioRag.Api.Options;
using PortfolioRag.Api.Services;

// Linux App Service has no regional culture set, so "C" would print a generic currency sign. Use US formatting everywhere.
CultureInfo.DefaultThreadCurrentCulture = CultureInfo.DefaultThreadCurrentUICulture = new CultureInfo("en-US");

var builder = WebApplication.CreateBuilder(args);

// ---- Configuration (values come from appsettings + user-secrets; see README) ----
builder.Services.Configure<AzureOpenAIOptions>(builder.Configuration.GetSection(AzureOpenAIOptions.Section));
builder.Services.Configure<AzureSearchOptions>(builder.Configuration.GetSection(AzureSearchOptions.Section));
builder.Services.Configure<BlobStorageOptions>(builder.Configuration.GetSection(BlobStorageOptions.Section));
var gateway = builder.Configuration.GetSection(GatewayOptions.Section).Get<GatewayOptions>() ?? new GatewayOptions();
var ui = builder.Configuration.GetSection(UiOptions.Section).Get<UiOptions>() ?? new UiOptions();

// ---- Data ----
builder.Services.AddDbContext<AppDbContext>(o => o.UseSqlServer(builder.Configuration.GetConnectionString("Sql")));

// ---- Services ----
// SDK clients are thread-safe and expensive to create -> Singleton.
builder.Services.AddSingleton<OpenAIService>();
builder.Services.AddSingleton<SearchService>();
builder.Services.AddSingleton<BlobStorageService>();
builder.Services.AddSingleton<PdfService>();
// Anything that uses the DbContext -> Scoped (one per HTTP request).
builder.Services.AddScoped<PortfolioService>();
builder.Services.AddScoped<ReviewService>();
builder.Services.AddScoped<IngestionService>();
builder.Services.AddScoped<RagChatService>();

builder.Services.AddControllers();
builder.Services.AddOpenApi();
builder.Services.AddProblemDetails();
builder.Services.AddCors(o => o.AddPolicy("ui", p => p
    .WithOrigins("http://localhost:4200")
    .AllowAnyHeader()
    .AllowAnyMethod()));

var app = builder.Build();

// ---- One-time setup: database + seed, blob container, search index ----
using (var scope = app.Services.CreateScope())
{
    var log = scope.ServiceProvider.GetRequiredService<ILogger<Program>>();

    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.EnsureCreated();   // POC only. Use EF migrations in real projects.
    SeedData.Seed(db);

    try { await scope.ServiceProvider.GetRequiredService<BlobStorageService>().EnsureContainerAsync(); }
    catch (Exception ex) { log.LogWarning(ex, "Blob Storage not ready. Check BlobStorage settings."); }

    try { await scope.ServiceProvider.GetRequiredService<SearchService>().EnsureIndexAsync(); }
    catch (Exception ex) { log.LogWarning(ex, "Azure AI Search not ready. Check AzureSearch settings."); }
}

app.UseExceptionHandler();
if (app.Environment.IsDevelopment())
    app.MapOpenApi();   // JSON spec at /openapi/v1.json

// On AKS, TLS ends at API Management; inside the cluster traffic is plain HTTP on port 8080.
if (!app.Environment.IsProduction()) app.UseHttpsRedirection();

// The Angular build is copied into wwwroot inside the container (see Dockerfile).
app.UseDefaultFiles();
app.UseStaticFiles();

app.UseCors("ui");   // only needed locally (ng serve on :4200)

// API Management adds a secret header to every call it forwards. Calls to /api that skip APIM are rejected,
// so rate limits, CORS and logging in APIM can't be bypassed by calling the cluster IP directly.
if (!string.IsNullOrEmpty(gateway.SharedSecret))
{
    var expected = Encoding.UTF8.GetBytes(gateway.SharedSecret);
    app.Use(async (ctx, next) =>
    {
        if (ctx.Request.Path.StartsWithSegments("/api"))
        {
            var sent = Encoding.UTF8.GetBytes(ctx.Request.Headers[gateway.HeaderName].ToString());
            if (!CryptographicOperations.FixedTimeEquals(sent, expected))   // constant-time compare
            {
                ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                await ctx.Response.WriteAsJsonAsync(new { error = "Call the API through API Management." });
                return;
            }
        }
        await next();
    });
}
app.MapControllers();
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));             // Kubernetes probes + pipeline smoke test
app.MapGet("/config.json", () => Results.Ok(new { apiBase = ui.ApiBase }));  // Angular reads this at startup
app.MapFallbackToFile("index.html");   // Angular routes

app.Run();
