namespace ApimSample.MvcClient.Models;

public class ApiSource
{
    /// <summary>ApimSample.Api — zero-trust API secured with Entra ID App Roles behind APIM.</summary>
    public const string DirectAuth = "DirectAuth";

    /// <summary>ApimSample.ApimSecuredApi — API where APIM performs all authentication (not yet deployed).</summary>
    public const string ApimAuth = "ApimAuth";
}

public class WeatherForecastViewModel
{
    public IEnumerable<WeatherForecast> Forecasts { get; set; } = Enumerable.Empty<WeatherForecast>();
    public string ApiSource { get; set; } = string.Empty;
    public bool Success { get; set; }
    public string ErrorMessage { get; set; } = string.Empty;

    /// <summary>Friendly name of the API that was called.</summary>
    public string DisplayName { get; set; } = string.Empty;

    /// <summary>Short description of how the API is secured.</summary>
    public string SecurityModel { get; set; } = string.Empty;

    /// <summary>True when the target API has not been published to Azure yet.</summary>
    public bool NotDeployed { get; set; }
}
