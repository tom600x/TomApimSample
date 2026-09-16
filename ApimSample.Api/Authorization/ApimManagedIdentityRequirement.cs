using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Options;
using ApimSample.Api.Options;

namespace ApimSample.Api.Authorization;

/// <summary>
/// Authorization requirement enforcing that the caller is Azure API Management, identified by the
/// object ID (oid claim) of APIM's managed identity. This is the application-layer control that
/// complements network isolation (disabled public access + private endpoint): even if network
/// controls were misconfigured, the API will still reject tokens not issued to APIM's identity.
/// </summary>
public class ApimManagedIdentityRequirement : IAuthorizationRequirement
{
}

public class ApimManagedIdentityHandler : AuthorizationHandler<ApimManagedIdentityRequirement>
{
    private readonly ApiSecurityOptions _options;
    private readonly ILogger<ApimManagedIdentityHandler> _logger;

    public ApimManagedIdentityHandler(IOptions<ApiSecurityOptions> options, ILogger<ApimManagedIdentityHandler> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    protected override Task HandleRequirementAsync(
        AuthorizationHandlerContext context,
        ApimManagedIdentityRequirement requirement)
    {
        if (!_options.EnforceManagedIdentityTrust)
        {
            // Managed identity trust enforcement disabled (e.g. local/dev testing with a user token).
            context.Succeed(requirement);
            return Task.CompletedTask;
        }

        if (string.IsNullOrWhiteSpace(_options.AllowedManagedIdentityObjectId))
        {
            _logger.LogError("ApiSecurity:AllowedManagedIdentityObjectId is not configured but enforcement is enabled.");
            context.Fail();
            return Task.CompletedTask;
        }

        // Managed identity tokens carry the identity's object id in the 'oid' claim.
        var oid = context.User.FindFirst("oid")?.Value;

        if (string.Equals(oid, _options.AllowedManagedIdentityObjectId, StringComparison.OrdinalIgnoreCase))
        {
            context.Succeed(requirement);
        }
        else
        {
            _logger.LogWarning("Rejected caller with oid '{Oid}': does not match the trusted APIM managed identity.", oid);
            context.Fail();
        }

        return Task.CompletedTask;
    }
}
