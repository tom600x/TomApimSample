namespace ApimSample.MvcClient;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Add services to the container.
        builder.Services.AddControllersWithViews();
        
        // Register the weather service and token service
        builder.Services.AddScoped<Services.IWeatherService, Services.WeatherService>();
        builder.Services.AddScoped<Services.ITokenService, Services.TokenService>();

        // Add HttpClient for API communication with OAuth token handling
        builder.Services.AddHttpClient("ApiClient", client =>
        {
            client.BaseAddress = new Uri(builder.Configuration["ApiSettings:BaseUrl"] ?? "https://tomoapim.azure-api.net");
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
