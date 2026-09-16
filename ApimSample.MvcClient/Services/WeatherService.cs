using System.Text.Json;
using ApimSample.MvcClient.Models;
using ApimSample.MvcClient.Options;
using Microsoft.Extensions.Options;

namespace ApimSample.MvcClient.Services;

public interface IWeatherService
{
    Task<WeatherForecastViewModel> GetWeatherForecastAsync(string apiSource);
}

public class WeatherService : IWeatherService
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ApiSettingsOptions _apiSettings;
    private readonly ILogger<WeatherService> _logger;
    private readonly ITokenService _tokenService;

    public WeatherService(
        IHttpClientFactory httpClientFactory,
        IOptions<ApiSettingsOptions> apiSettings,
        ILogger<WeatherService> logger,
        ITokenService tokenService)
    {
        _httpClientFactory = httpClientFactory;
        _apiSettings = apiSettings.Value;
        _logger = logger;
        _tokenService = tokenService;
    }

    public async Task<WeatherForecastViewModel> GetWeatherForecastAsync(string apiSource)
    {
        var viewModel = new WeatherForecastViewModel { ApiSource = apiSource };

        if (!_apiSettings.Endpoints.TryGetValue(apiSource, out var endpoint))
        {
            viewModel.Success = false;
            viewModel.ErrorMessage = $"No endpoint is configured for '{apiSource}' under ApiSettings:Endpoints.";
            return viewModel;
        }

        viewModel.DisplayName = endpoint.DisplayName;
        viewModel.SecurityModel = endpoint.SecurityModel;

        // ApimSample.ApimSecuredApi exists in the solution but has not been published to Azure yet,
        // so surface a clear message instead of failing with a confusing error from the gateway.
        if (!endpoint.Deployed || string.IsNullOrWhiteSpace(endpoint.Path))
        {
            viewModel.Success = false;
            viewModel.NotDeployed = true;
            viewModel.ErrorMessage =
                $"'{endpoint.DisplayName}' is not deployed to Azure yet, so there is nothing to call through " +
                "API Management. Publish the project to an App Service, import it into APIM, then set " +
                $"ApiSettings:Endpoints:{apiSource}:Path and Deployed=true.";
            return viewModel;
        }

        try
        {
            var client = _httpClientFactory.CreateClient("ApiClient");

            // APIM requires a subscription key on every call, in addition to the OAuth token.
            if (!string.IsNullOrWhiteSpace(_apiSettings.SubscriptionKey))
            {
                client.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", _apiSettings.SubscriptionKey);
            }
            else
            {
                _logger.LogWarning("ApiSettings:SubscriptionKey is not configured; APIM will reject the call with 401.");
            }

            // Acquire an app-only token for ApimSample.Api. APIM validates this token
            // (issuer, tenant, audience and the Api.Access app role) before it forwards the request,
            // and then re-authenticates to the backend using its own managed identity.
            var accessToken = await _tokenService.GetAccessTokenAsync();
            if (string.IsNullOrEmpty(accessToken))
            {
                _logger.LogError("Failed to acquire an OAuth token for {ApiSource}", apiSource);
                viewModel.Success = false;
                viewModel.ErrorMessage = "Authentication failed: could not acquire an access token. Check the AzureAd settings and the client secret.";
                return viewModel;
            }

            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", accessToken);

            _logger.LogInformation("Calling {Path} through APIM for {ApiSource}", endpoint.Path, apiSource);

            var response = await client.GetAsync(endpoint.Path);

            if (response.IsSuccessStatusCode)
            {
                var content = await response.Content.ReadAsStringAsync();
                var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                viewModel.Forecasts = JsonSerializer.Deserialize<IEnumerable<WeatherForecast>>(content, options)
                                      ?? Enumerable.Empty<WeatherForecast>();
                viewModel.Success = true;

                _logger.LogInformation("Successfully retrieved weather data from {ApiSource}", apiSource);
            }
            else
            {
                var errorContent = await response.Content.ReadAsStringAsync();
                _logger.LogError("API request to {ApiSource} failed with {StatusCode}. Response: {ErrorContent}",
                    apiSource, response.StatusCode, errorContent);

                viewModel.Success = false;
                viewModel.ErrorMessage = $"API returned status code: {(int)response.StatusCode} - {response.StatusCode}";

                viewModel.ErrorMessage += response.StatusCode switch
                {
                    System.Net.HttpStatusCode.Unauthorized =>
                        " - APIM rejected the token or the subscription key. Verify ApiSettings:SubscriptionKey and that the token audience is the ApimSample.Api Application ID URI.",
                    System.Net.HttpStatusCode.Forbidden =>
                        " - The token was valid but lacked the 'Api.Access' app role, or the backend did not trust the caller. Confirm the Api.Access app role assignment for ApimSample.Swagger.",
                    _ => string.Empty
                };
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
