using ApimSample.MvcClient.Options;

namespace ApimSample.MvcClient;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Add services to the container.
        builder.Services.AddControllersWithViews();

        // Strongly typed configuration.
        builder.Services.AddOptions<ApiSettingsOptions>()
            .Bind(builder.Configuration.GetSection(ApiSettingsOptions.SectionName))
            .ValidateOnStart();
        builder.Services.AddOptions<AzureAdClientOptions>()
            .Bind(builder.Configuration.GetSection(AzureAdClientOptions.SectionName))
            .ValidateOnStart();

        builder.Services.AddScoped<Services.IWeatherService, Services.WeatherService>();

        // Singleton so the acquired app-only token is cached and reused across requests.
        builder.Services.AddSingleton<Services.ITokenService, Services.TokenService>();

        var apimBaseUrl = builder.Configuration[$"{ApiSettingsOptions.SectionName}:BaseUrl"];
        if (string.IsNullOrWhiteSpace(apimBaseUrl))
        {
            throw new InvalidOperationException($"{ApiSettingsOptions.SectionName}:BaseUrl must be configured (the APIM gateway URL).");
        }

        // All API traffic goes through the API Management gateway - never directly to the backend App Service.
        builder.Services.AddHttpClient("ApiClient", client =>
        {
            client.BaseAddress = new Uri(apimBaseUrl);
            client.DefaultRequestHeaders.Add("Accept", "application/json");
        });

        // Add a dedicated HttpClient for token requests (without base address)
        builder.Services.AddHttpClient("TokenClient");

        var app = builder.Build();

        // Configure the HTTP request pipeline.
        if (!app.Environment.IsDevelopment())
        {
            app.UseExceptionHandler("/Home/Error");
        }
        app.UseStaticFiles();

        app.UseRouting();

        app.UseAuthorization();

        app.MapControllerRoute(
            name: "default",
            pattern: "{controller=Home}/{action=Index}/{id?}");

        app.Run();
    }
}
