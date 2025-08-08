using System.Text.Json;
using ApimSample.MvcClient.Models;

namespace ApimSample.MvcClient.Services;

public interface IWeatherService
{
    Task<WeatherForecastViewModel> GetWeatherForecastAsync(string apiSource);
}

public class WeatherService : IWeatherService
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IConfiguration _configuration;
    private readonly ILogger<WeatherService> _logger;
    private readonly ITokenService _tokenService;

    public WeatherService(IHttpClientFactory httpClientFactory, IConfiguration configuration, 
        ILogger<WeatherService> logger, ITokenService tokenService)
    {
        _httpClientFactory = httpClientFactory;
        _configuration = configuration;
        _logger = logger;
        _tokenService = tokenService;
    }

    public async Task<WeatherForecastViewModel> GetWeatherForecastAsync(string apiSource)
    {
        var viewModel = new WeatherForecastViewModel { ApiSource = apiSource };
        
        try
        {
            var client = _httpClientFactory.CreateClient("ApiClient");
            
            // Add APIM subscription key to header (required for both flows)
            client.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", _configuration["ApiSettings:ApiKey"]);
            
            // Set the endpoint based on which API we're targeting through APIM
            string endpoint;
            
            if (apiSource == ApiSource.DirectAuth)
            {
                // DirectAuth: APIM passes OAuth token to API, API validates it
                endpoint = "/direct-auth-api/weatherforecast";
                
                // Get OAuth token for the API backend
                var accessToken = await _tokenService.GetAccessTokenAsync();
                if (string.IsNullOrEmpty(accessToken))
                {
                    _logger.LogError("Failed to acquire OAuth token for DirectAuth flow");
                    viewModel.Success = false;
                    viewModel.ErrorMessage = "Authentication failed: Could not acquire access token";
                    return viewModel;
                }
                
                // Add the bearer token - APIM will pass this through to the API
                client.DefaultRequestHeaders.Authorization = 
                    new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", accessToken);
                
                _logger.LogInformation("Added Bearer token for DirectAuth flow (API validates token)");
            }
            else // ApiSource.ApimAuth
            {
                // ApimAuth: APIM validates OAuth token, then forwards to API without auth
                endpoint = "/apim-secured-api/weatherforecast";
                
                // Get OAuth token for APIM validation
                var accessToken = await _tokenService.GetAccessTokenAsync();
                if (string.IsNullOrEmpty(accessToken))
                {
                    _logger.LogError("Failed to acquire OAuth token for ApimAuth flow");
                    viewModel.Success = false;
                    viewModel.ErrorMessage = "Authentication failed: Could not acquire access token";
                    return viewModel;
                }
                
                // Add the bearer token - APIM will validate this token
                client.DefaultRequestHeaders.Authorization = 
                    new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", accessToken);
                
                _logger.LogInformation("Added Bearer token for ApimAuth flow (APIM validates token)");
            }
            
            _logger.LogInformation("Calling API endpoint: {Endpoint} for source: {ApiSource}", endpoint, apiSource);
            
            var response = await client.GetAsync(endpoint);
            
            if (response.IsSuccessStatusCode)
            {
                var content = await response.Content.ReadAsStringAsync();
                var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                var weatherData = JsonSerializer.Deserialize<IEnumerable<WeatherForecast>>(content, options);
                viewModel.Forecasts = weatherData ?? Enumerable.Empty<WeatherForecast>();
                viewModel.Success = true;
                
                _logger.LogInformation("Successfully retrieved weather data from {ApiSource}", apiSource);
            }
            else
            {
                var errorContent = await response.Content.ReadAsStringAsync();
                _logger.LogError("API request to {ApiSource} failed with status code {StatusCode}. Response: {ErrorContent}", 
                    apiSource, response.StatusCode, errorContent);
                viewModel.Success = false;
                viewModel.ErrorMessage = $"API returned status code: {(int)response.StatusCode} - {response.StatusCode}";
                
                if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                {
                    viewModel.ErrorMessage += " - Authentication failed. Please check your OAuth configuration.";
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error fetching weather forecast data from {ApiSource}", apiSource);
            viewModel.Success = false;
            viewModel.ErrorMessage = $"Error: {ex.Message}";
        }
        
        return viewModel;
    }
}
