using ApimSample.Api.Authorization;
using ApimSample.Api.Middleware;
using ApimSample.Api.Options;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Identity.Web;
using Microsoft.OpenApi;

namespace ApimSample.Api;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Strongly typed configuration, validated at startup (fail fast on misconfiguration).
        builder.Services
            .AddOptions<ApiSecurityOptions>()
            .Bind(builder.Configuration.GetSection(ApiSecurityOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        var apiSecurity = builder.Configuration.GetSection(ApiSecurityOptions.SectionName).Get<ApiSecurityOptions>()
                           ?? new ApiSecurityOptions();

        builder.Services.AddControllers();

        // Public network access to this App Service is disabled; it is reachable only via the
        // Private Endpoint from Azure API Management. CORS is still restricted defensively to the
        // APIM gateway origin in case the API is ever exercised from a browser context.
        builder.Services.AddCors(options =>
        {
            options.AddPolicy("AllowApimGatewayOnly", policy =>
            {
                if (apiSecurity.AllowedOrigins.Length > 0)
                {
                    policy.WithOrigins(apiSecurity.AllowedOrigins)
                          .AllowAnyMethod()
                          .AllowAnyHeader();
                }
                else
                {
                    // No caller should be reaching this API directly from a browser; deny by default.
                    policy.WithOrigins(Array.Empty<string>());
                }
            });
        });

        // Microsoft.Identity.Web wires JWT bearer auth to Microsoft Entra ID using the "AzureAd"
        // configuration section (Instance, TenantId, ClientId/Audience) and understands app roles.
        builder.Services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

        builder.Services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
        {
            var azureAd = builder.Configuration.GetSection("AzureAd");
            var tenantId = azureAd["TenantId"];
            var instance = azureAd["Instance"]?.TrimEnd('/');

            // Keep the original short claim names from the token ("roles", "oid", "azp"). Without this the
            // JWT handler rewrites "roles" to the long ClaimTypes.Role URI, which would no longer match
            // RoleClaimType below and every role check (and the oid lookup) would silently fail with 403.
            options.MapInboundClaims = false;

            // Explicitly validate issuer, audience, tenant, lifetime, and signature. Microsoft.Identity.Web
            // already sets most of this from the AzureAd section, but we re-assert it here to make the
            // production security posture explicit and reviewable.
            options.TokenValidationParameters.ValidateIssuer = true;
            options.TokenValidationParameters.ValidIssuers = new[]
            {
                $"{instance}/{tenantId}/v2.0",
                $"https://sts.windows.net/{tenantId}/"
            };
            options.TokenValidationParameters.ValidateAudience = true;
            options.TokenValidationParameters.ValidAudiences = new[]
            {
                azureAd["Audience"],
                azureAd["ClientId"]
            };
            options.TokenValidationParameters.ValidateLifetime = true;
            options.TokenValidationParameters.ValidateIssuerSigningKey = true;
            options.TokenValidationParameters.RequireSignedTokens = true;
            options.TokenValidationParameters.RoleClaimType = "roles";
            options.TokenValidationParameters.NameClaimType = "name";

            options.Events ??= new JwtBearerEvents();
            var originalOnTokenValidated = options.Events.OnTokenValidated;
            options.Events.OnTokenValidated = async context =>
            {
                if (originalOnTokenValidated is not null)
                {
                    await originalOnTokenValidated(context);
                }

                var logger = context.HttpContext.RequestServices
                    .GetRequiredService<ILoggerFactory>()
                    .CreateLogger("TokenValidation");
                logger.LogInformation(
                    "Token validated for oid={Oid}, appid={AppId}, roles={Roles}",
                    context.Principal?.FindFirst("oid")?.Value,
                    context.Principal?.FindFirst("azp")?.Value ?? context.Principal?.FindFirst("appid")?.Value,
                    string.Join(",", context.Principal?.FindAll("roles").Select(c => c.Value) ?? Array.Empty<string>()));
            };

            options.Events.OnAuthenticationFailed = context =>
            {
                var logger = context.HttpContext.RequestServices
                    .GetRequiredService<ILoggerFactory>()
                    .CreateLogger("TokenValidation");
                logger.LogWarning(context.Exception, "JWT authentication failed.");
                return Task.CompletedTask;
            };
        });

        // Policy-based authorization: every request must present the Api.Access app role, and (when
        // enforcement is enabled) originate from APIM's managed identity so the API rejects any caller
        // that bypassed APIM even if network isolation were ever misconfigured.
        builder.Services.AddSingleton<IAuthorizationHandler, ApimManagedIdentityHandler>();
        builder.Services.AddAuthorization(options =>
        {
            options.AddPolicy("ApiAccess", policy =>
            {
                policy.RequireAuthenticatedUser();
                policy.RequireRole(apiSecurity.RequiredAppRole);
                policy.AddRequirements(new ApimManagedIdentityRequirement());
            });

            options.DefaultPolicy = options.GetPolicy("ApiAccess")!;
        });

        // Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
        builder.Services.AddEndpointsApiExplorer();
        builder.Services.AddSwaggerGen(c =>
        {
            c.SwaggerDoc("v1", new OpenApiInfo { Title = "APIM Sample API", Version = "v1" });

            var azureAd = builder.Configuration.GetSection("AzureAd");
            var authority = $"{azureAd["Instance"]?.TrimEnd('/')}/{azureAd["TenantId"]}";
            var audience = azureAd["Audience"] ?? $"api://{azureAd["ClientId"]}";

            // Swagger UI uses the OAuth2 Authorization Code + PKCE flow so a signed-in developer can
            // obtain a delegated token carrying the Api.Access app role for interactive testing.
            c.AddSecurityDefinition("oauth2", new OpenApiSecurityScheme
            {
                Type = SecuritySchemeType.OAuth2,
                Flows = new OpenApiOAuthFlows
                {
                    AuthorizationCode = new OpenApiOAuthFlow
                    {
                        AuthorizationUrl = new Uri($"{authority}/oauth2/v2.0/authorize"),
                        TokenUrl = new Uri($"{authority}/oauth2/v2.0/token"),
                        Scopes = new Dictionary<string, string>
                        {
                            { $"{audience}/.default", "Access ApimSample API as the signed-in user" }
                        }
                    }
                }
            });

            c.AddSecurityRequirement(document => new OpenApiSecurityRequirement
            {
                {
                    new OpenApiSecuritySchemeReference("oauth2", document, null),
                    new List<string> { $"{audience}/.default" }
                }
            });
        });

        var app = builder.Build();

        // Security headers should be applied to every response, including error pages.
        app.UseSecurityHeaders();

        app.UseHttpsRedirection();

        if (!app.Environment.IsDevelopment())
        {
            app.UseHsts();
        }

        // Swagger is exposed for developer testing through APIM/Front Door; disable in production
        // if the API must never expose its schema outside the APIM developer portal.
        app.UseSwagger();
        app.UseSwaggerUI(c =>
        {
            c.SwaggerEndpoint("/swagger/v1/swagger.json", "APIM Sample API v1");
            c.OAuthClientId(apiSecurity.SwaggerClientId);
            c.OAuthUsePkce();
        });

        app.UseCors("AllowApimGatewayOnly");

        app.UseAuthentication();
        app.UseAuthorization();

        app.MapControllers();

        app.Run();
    }
}
