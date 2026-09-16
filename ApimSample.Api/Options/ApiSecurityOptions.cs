namespace ApimSample.Api.Options;

/// <summary>
/// Strongly typed application security configuration bound from the "ApiSecurity" configuration section.
/// Controls App Role enforcement and the defense-in-depth check that restricts callers to the
/// Azure API Management managed identity, since the App Service only trusts traffic that has
/// already been authorized by APIM and forwarded over the private endpoint.
/// </summary>
public class ApiSecurityOptions
{
    public const string SectionName = "ApiSecurity";

    /// <summary>
    /// The App Role required to call this API (application permission granted to APIM's managed identity
    /// and/or delegated permission granted to interactive callers such as Swagger).
    /// </summary>
    public string RequiredAppRole { get; set; } = "Api.Access";

    /// <summary>
    /// Object ID (principal ID) of the Azure API Management system-assigned (or user-assigned) managed identity.
    /// When <see cref="EnforceManagedIdentityTrust"/> is true, only bearer tokens issued to this identity
    /// (oid claim) are accepted, guaranteeing the backend API only trusts calls that traversed APIM.
    /// </summary>
    public string? AllowedManagedIdentityObjectId { get; set; }

    /// <summary>
    /// When true, enforces that the caller's oid/azp claim matches <see cref="AllowedManagedIdentityObjectId"/>.
    /// Disable only for local development/testing with delegated (user) tokens via Swagger.
    /// </summary>
    public bool EnforceManagedIdentityTrust { get; set; }

    /// <summary>
    /// Client ID of the public client application (e.g. Swagger UI) used to obtain the OAuth2 Authorization
    /// Code + PKCE flow for interactive API testing.
    /// </summary>
    public string? SwaggerClientId { get; set; }

    /// <summary>
    /// Origins allowed to call this API directly (typically only the APIM gateway hostname, since public
    /// network access to the App Service is disabled and all traffic arrives via the private endpoint).
    /// </summary>
    public string[] AllowedOrigins { get; set; } = Array.Empty<string>();
}
