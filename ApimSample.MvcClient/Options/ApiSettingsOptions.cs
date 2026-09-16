namespace ApimSample.MvcClient.Options;

/// <summary>
/// Strongly typed settings describing how this client reaches the APIs through Azure API Management.
/// </summary>
public class ApiSettingsOptions
{
    public const string SectionName = "ApiSettings";

    /// <summary>APIM gateway base URL, e.g. https://tomapim.azure-api.net.</summary>
    public string BaseUrl { get; set; } = string.Empty;

    /// <summary>APIM subscription key sent in the Ocp-Apim-Subscription-Key header.</summary>
    public string SubscriptionKey { get; set; } = string.Empty;

    /// <summary>
    /// Per-API routing information, keyed by <see cref="Models.ApiSource"/> value.
    /// An entry with an empty <see cref="ApiEndpointOptions.Path"/> is treated as "not deployed".
    /// </summary>
    public Dictionary<string, ApiEndpointOptions> Endpoints { get; set; } = new();
}

public class ApiEndpointOptions
{
    /// <summary>Friendly name shown in the UI.</summary>
    public string DisplayName { get; set; } = string.Empty;

    /// <summary>Path appended to the APIM gateway base URL. Empty means the API is not deployed yet.</summary>
    public string Path { get; set; } = string.Empty;

    /// <summary>Short description of how this API is secured, shown in the UI.</summary>
    public string SecurityModel { get; set; } = string.Empty;

    /// <summary>Set to false for APIs that exist in the solution but are not yet published to Azure.</summary>
    public bool Deployed { get; set; }
}

/// <summary>
/// Entra ID (Azure AD) client credentials used to acquire an access token for the API.
/// The client is <c>ApimSample.Swagger</c>; the resource is <c>ApimSample.Api</c>.
/// </summary>
public class AzureAdClientOptions
{
    public const string SectionName = "AzureAd";

    public string Instance { get; set; } = "https://login.microsoftonline.com/";
    public string TenantId { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
    public string ClientSecret { get; set; } = string.Empty;

    /// <summary>
    /// Must be the API's Application ID URI followed by <c>/.default</c>. With App Roles (rather than
    /// delegated scopes) the client-credentials flow always requests <c>/.default</c>, and Entra ID
    /// stamps the assigned application roles into the token's <c>roles</c> claim.
    /// </summary>
    public string Scope { get; set; } = string.Empty;

    public string Authority => $"{Instance.TrimEnd('/')}/{TenantId}";
    public string TokenEndpoint => $"{Authority}/oauth2/v2.0/token";
}
