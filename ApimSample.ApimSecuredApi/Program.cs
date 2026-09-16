using Microsoft.OpenApi;

namespace ApimSample.ApimSecuredApi;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Add services to the container
        builder.Services.AddControllers();



        // In Program.cs:



        // Note: No authentication is set up here - APIM will handle it

        // Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
        builder.Services.AddEndpointsApiExplorer();
        builder.Services.AddSwaggerGen(c =>
        {
            c.SwaggerDoc("v1", new OpenApiInfo { Title = "APIM Secured API", Version = "v1" });

            // Add note about API Management handling security
            c.AddSecurityDefinition("apiManagement", new OpenApiSecurityScheme
            {
                Type = SecuritySchemeType.ApiKey,
                In = ParameterLocation.Header,
                Name = "Ocp-Apim-Subscription-Key",
                Description = "API Management subscription key. Authentication is handled by Azure API Management."
            });

            c.AddSecurityRequirement(document => new OpenApiSecurityRequirement
            {
                {
                    new OpenApiSecuritySchemeReference("apiManagement", document, null),
                    new List<string>()
                }
            });
        });

        var app = builder.Build();
        app.UseMiddleware<CookieResponseMiddleware>();
        // Configure the HTTP request pipeline
        if (app.Environment.IsDevelopment())
        {
            app.UseSwagger();
            app.UseSwaggerUI(c =>
            {
                c.SwaggerEndpoint("/swagger/v1/swagger.json", "APIM Secured API v1");
            });
        }
        app.UseCookiePolicy();
        app.MapControllers();

        app.Run();
    }


    // Helper method to handle SameSite compatibility
    //static void CheckSameSite(HttpContext httpContext, CookieOptions options)
    //{
    //    if (options.SameSite == SameSiteMode.None)
    //    {
    //        var userAgent = httpContext.Request.Headers["User-Agent"].ToString();
    //        if (DisallowsSameSiteNone(userAgent))
    //        {
    //            options.SameSite = SameSiteMode.Unspecified;
    //        }
    //    }
    //}

    // Check if the user agent disallows SameSite=None
    //static bool DisallowsSameSiteNone(string userAgent)
    //{
    //     Cover all iOS based browsers here. This includes:
    //     - Safari on iOS 12 for iPhone, iPod Touch, iPad
    //     - WkWebview on iOS 12 for iPhone, iPod Touch, iPad
    //     - Chrome on iOS 12 for iPhone, iPod Touch, iPad
    //     All of which are broken by SameSite=None, because they use the iOS networking stack
    //    if (userAgent.Contains("CPU iPhone OS 12") || userAgent.Contains("iPad; OS 12"))
    //    {
    //        return true;
    //    }

    //     Cover Mac OS X based browsers that use the Mac OS networking stack. 
    //     This includes:
    //     - Safari on Mac OS X.
    //     This does not include:
    //     - Chrome on Mac OS X
    //     Because they do not use the Mac OS networking stack.
    //    if (userAgent.Contains("Macintosh; Intel Mac OS X 10_14") &&
    //        userAgent.Contains("Version/") && userAgent.Contains("Safari"))
    //    {
    //        return true;
    //    }

    //     Cover Chrome 50-69, because some versions are broken by SameSite=None, 
    //     and none in this range require it.
    //    if (userAgent.Contains("Chrome/5") || userAgent.Contains("Chrome/6"))
    //    {
    //        return true;
    //    }

    //    return false;
    //}

    public class CookieResponseMiddleware
    {
        private readonly RequestDelegate _next;
        private readonly ILogger<CookieResponseMiddleware> _logger;

        public CookieResponseMiddleware(RequestDelegate next, ILogger<CookieResponseMiddleware> logger)
        {
            _next = next;
            _logger = logger;
        }

        public async Task InvokeAsync(HttpContext context)
        {
            // Wrap the response body stream to intercept headers
            var originalResponseHeaders = context.Response.Headers;

            // Continue with the request
            await _next(context);

            // After the response is generated, modify cookies
            ModifyResponseCookies(context);
        }

        private void ModifyResponseCookies(HttpContext context)
        {
            if (context.Response.Headers.TryGetValue("Set-Cookie", out var cookieValues))
            {
                var modifiedCookies = new List<string>();

                foreach (var cookieValue in cookieValues)
                {
                    var cookie = cookieValue.ToString();
                    _logger.LogInformation($"Original cookie: {cookie}");

                    // Process ARRAffinity cookies specifically
                    if (cookie.Contains("ARRAffinity", StringComparison.OrdinalIgnoreCase))
                    {
                        // Remove existing SameSite attributes
                        cookie = System.Text.RegularExpressions.Regex.Replace(
                            cookie,
                            @";\s*SameSite\s*=\s*[^;]*",
                            "",
                            System.Text.RegularExpressions.RegexOptions.IgnoreCase);

                        // Ensure it ends with SameSite=Lax
                        if (!cookie.Contains("SameSite", StringComparison.OrdinalIgnoreCase))
                        {
                            cookie += "; SameSite=Lax";
                        }

                        _logger.LogInformation($"Modified cookie: {cookie}");
                    }

                    modifiedCookies.Add(cookie);
                }

                // Replace the Set-Cookie headers
                context.Response.Headers.Remove("Set-Cookie");
                foreach (var modifiedCookie in modifiedCookies)
                {
                    context.Response.Headers.Append("Set-Cookie", modifiedCookie);
                }
            }
        }
    }



}
