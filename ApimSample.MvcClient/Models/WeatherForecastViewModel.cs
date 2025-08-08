namespace ApimSample.MvcClient.Models;

public class ApiSource
{
    public const string DirectAuth = "DirectAuth";
    public const string ApimAuth = "ApimAuth";
}

public class WeatherForecastViewModel
{
    public IEnumerable<WeatherForecast> Forecasts { get; set; } = Enumerable.Empty<WeatherForecast>();
    public string ApiSource { get; set; } = string.Empty;
    public bool Success { get; set; }
    public string ErrorMessage { get; set; } = string.Empty;
}
