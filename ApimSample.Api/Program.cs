using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;

namespace ApimSample.Api;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Add services to the container
        builder.Services.AddControllers();
        
        // Add CORS support for APIM
        builder.Services.AddCors(options =>
        {
            options.AddPolicy("AllowAPIM", policy =>
            {
                policy.AllowAnyOrigin()
                      .AllowAnyMethod()
                      .AllowAnyHeader();
            });
        });
        
        // Configure JWT Authentication
        builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.Authority = builder.Configuration["Authentication:Authority"];
                options.Audience = builder.Configuration["Authentication:Audience"];
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidateAudience = true,
                    ValidateLifetime = true,
                    ValidateIssuerSigningKey = true
                };
            });

        // Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
        builder.Services.AddEndpointsApiExplorer();
        builder.Services.AddSwaggerGen(c =>
        {
            c.SwaggerDoc("v1", new OpenApiInfo { Title = "APIM Sample API", Version = "v1" });

      
            // Add OAuth security definition to Swagger
            c.AddSecurityDefinition("oauth2", new OpenApiSecurityScheme
            {
                Type = SecuritySchemeType.OAuth2,
                Flows = new OpenApiOAuthFlows
                {
                    Implicit = new OpenApiOAuthFlow
                    {
                        AuthorizationUrl = new Uri($"{builder.Configuration["Authentication:Authority"]}/oauth2/v2.0/authorize"),
                        TokenUrl = new Uri($"{builder.Configuration["Authentication:Authority"]}/oauth2/v2.0/token"),
                        Scopes = new Dictionary<string, string>
            {
                { $"{builder.Configuration["Authentication:Audience"]}/weather.read", "Read weather data" }
            }
                    }
                }
            });

            c.AddSecurityRequirement(new OpenApiSecurityRequirement
{
    {
        new OpenApiSecurityScheme
        {
            Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "oauth2" }
        },
        new[] { $"{builder.Configuration["Authentication:Audience"]}/weather.read" }
    }
});
        });

        var app = builder.Build();

        // Configure the HTTP request pipeline
        if (app.Environment.IsDevelopment())
        {
            app.UseSwagger();
            app.UseSwaggerUI(c =>
            {
                c.SwaggerEndpoint("/swagger/v1/swagger.json", "APIM Sample API v1");
                c.OAuthClientId(app.Configuration["Authentication:SwaggerClientId"]);
                c.OAuthUsePkce(); // Add PKCE support for better security
            });
        }

        app.UseAuthentication();
        app.UseAuthorization();

        // Use CORS
        app.UseCors("AllowAPIM");

        app.MapControllers();

        app.Run();
    }
}
