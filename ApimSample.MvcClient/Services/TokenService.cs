using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ApimSample.MvcClient.Services;

public interface ITokenService
{
    Task<string?> GetAccessTokenAsync();
}

public class TokenService : ITokenService
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IConfiguration _configuration;
    private readonly ILogger<TokenService> _logger;
    private readonly SemaphoreSlim _tokenSemaphore = new(1, 1);
    
    private string? _cachedToken;
    private DateTime _tokenExpiry = DateTime.MinValue;

    public TokenService(IHttpClientFactory httpClientFactory, IConfiguration configuration, ILogger<TokenService> logger)
    {
        _httpClientFactory = httpClientFactory;
        _configuration = configuration;
        _logger = logger;
    }

    public async Task<string?> GetAccessTokenAsync()
    {
        // Check if we have a valid cached token
        if (!string.IsNullOrEmpty(_cachedToken) && DateTime.UtcNow < _tokenExpiry.AddMinutes(-5))
        {
            return _cachedToken;
        }

        await _tokenSemaphore.WaitAsync();
        try
        {
            // Double-check pattern - another thread might have refreshed the token
            if (!string.IsNullOrEmpty(_cachedToken) && DateTime.UtcNow < _tokenExpiry.AddMinutes(-5))
            {
                return _cachedToken;
            }

            return await AcquireNewTokenAsync();
        }
        finally
        {
            _tokenSemaphore.Release();
        }
    }

    private async Task<string?> AcquireNewTokenAsync()
    {
        try
        {
            var tenantId = _configuration["AzureAd:TenantId"];
            var clientId = _configuration["AzureAd:ClientId"];
            var clientSecret = _configuration["AzureAd:ClientSecret"];
            var scope = _configuration["AzureAd:Scope"];

            if (string.IsNullOrEmpty(tenantId) || string.IsNullOrEmpty(clientId) || 
                string.IsNullOrEmpty(clientSecret) || string.IsNullOrEmpty(scope))
            {
                _logger.LogError("OAuth configuration is incomplete. Missing required AzureAd settings.");
                return null;
            }

            var client = _httpClientFactory.CreateClient("TokenClient");
            var tokenEndpoint = $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token";

            var requestBody = new List<KeyValuePair<string, string>>
            {
                new("client_id", clientId),
                new("client_secret", clientSecret),
                new("scope", scope),
                new("grant_type", "client_credentials")
            };

            var content = new FormUrlEncodedContent(requestBody);
            
            _logger.LogInformation("Requesting OAuth token from {TokenEndpoint}", tokenEndpoint);
            _logger.LogDebug("Token request - ClientId: {ClientId}, Scope: {Scope}", clientId, scope);
            
            var response = await client.PostAsync(tokenEndpoint, content);
            
            if (!response.IsSuccessStatusCode)
            {
                var errorContent = await response.Content.ReadAsStringAsync();
                _logger.LogError("Token request failed with status {StatusCode}: {ErrorContent}", 
                    response.StatusCode, errorContent);
                return null;
            }

            var responseContent = await response.Content.ReadAsStringAsync();
            var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
            var tokenResponse = JsonSerializer.Deserialize<TokenResponse>(responseContent, options);

            if (tokenResponse?.AccessToken == null)
            {
                _logger.LogError("Token response did not contain access_token");
                return null;
            }

            _cachedToken = tokenResponse.AccessToken;
            _tokenExpiry = DateTime.UtcNow.AddSeconds(tokenResponse.ExpiresIn - 300); // Subtract 5 minutes for safety
            
            _logger.LogInformation("Successfully acquired OAuth token, expires at {TokenExpiry}", _tokenExpiry);
            
            return _cachedToken;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error acquiring OAuth token");
            return null;
        }
    }

    protected virtual void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tokenSemaphore?.Dispose();
        }
    }

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }
}

internal class TokenResponse
{
    [JsonPropertyName("access_token")]
    public string? AccessToken { get; set; }
    
    [JsonPropertyName("expires_in")]
    public int ExpiresIn { get; set; }
    
    [JsonPropertyName("token_type")]
    public string? TokenType { get; set; }
}
