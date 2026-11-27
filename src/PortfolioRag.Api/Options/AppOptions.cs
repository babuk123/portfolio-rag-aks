namespace PortfolioRag.Api.Options;

public class AzureOpenAIOptions
{
    public const string Section = "AzureOpenAI";
    public string Endpoint { get; set; } = "";
    public string ApiKey { get; set; } = "";
    public string ChatDeployment { get; set; } = "gpt-4.1-mini";
    public string EmbeddingDeployment { get; set; } = "text-embedding-3-small";
    public int EmbeddingDimensions { get; set; } = 1536;
}

public class AzureSearchOptions
{
    public const string Section = "AzureSearch";
    public string Endpoint { get; set; } = "";
    public string ApiKey { get; set; } = "";
    public string IndexName { get; set; } = "portfolio-docs";
    /// <summary>Number of chunks sent to the LLM.</summary>
    public int Top { get; set; } = 5;
    /// <summary>Semantic ranker needs Basic tier or higher.</summary>
    public bool UseSemanticRanker { get; set; } = false;
    /// <summary>Semantic reranker score is 0-4. Chunks below this are treated as "not relevant".</summary>
    public double MinRerankerScore { get; set; } = 1.5;
}

public class BlobStorageOptions
{
    public const string Section = "BlobStorage";
    /// <summary>"UseDevelopmentStorage=true" works with the Azurite emulator.</summary>
    public string ConnectionString { get; set; } = "UseDevelopmentStorage=true";
    public string Container { get; set; } = "portfolio-docs";
}

/// <summary>Shared secret that API Management adds as a header; requests to /api without it are rejected.</summary>
public class GatewayOptions
{
    public const string Section = "ApiGateway";
    /// <summary>Empty = check disabled (local runs). Set in the Kubernetes secret on AKS.</summary>
    public string SharedSecret { get; set; } = "";
    public string HeaderName { get; set; } = "X-Gateway-Secret";
}

/// <summary>Settings handed to the Angular app at runtime through /config.json.</summary>
public class UiOptions
{
    public const string Section = "Ui";
    /// <summary>Base URL the browser uses for API calls. Empty = same origin (local). On AKS = the APIM gateway URL.</summary>
    public string ApiBase { get; set; } = "";
}
