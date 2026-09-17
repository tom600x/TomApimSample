# Zero-Trust API Security with Azure API Management and Microsoft Entra ID

A reference implementation and how-to guide for making an ASP.NET Core API reachable **only**
through Azure API Management, by callers your organization has explicitly authorized.

```
Internet Client
    |  OAuth 2.0 access token (App Role: Api.Access)
    v
Microsoft Entra ID              issues and signs the token
    v
Azure Front Door + WAF          edge protection, OWASP rules, DDoS    (optional)
    v
Azure API Management            validates the caller's token, then discards it
    |                           and re-authenticates as its own managed identity
    v
Private Endpoint                the only network route into the backend
    v
ASP.NET Core API                public access disabled; trusts only APIM's identity
```

| Guide | Use it when |
|---|---|
| **This document** | You want to implement the pattern yourself, step by step |
| **[infra/README.md](infra/README.md)** | You want Bicep + PowerShell to provision everything automatically |
| **[docs/manual-azure-setup.md](docs/manual-azure-setup.md)** | You need click-by-click portal steps, no CLI/IaC |
| **[docs/security-architecture.md](docs/security-architecture.md)** | You want the *why* behind each control, recommendation levels, and Microsoft Learn references |

## Table of contents

- [Is this pattern right for you](#is-this-pattern-right-for-you)
- [How a request flows](#how-a-request-flows)
- [Implementing it yourself](#implementing-it-yourself)
- [Reference: this repository](#reference-this-repository)
- [Testing and verification](#testing-and-verification)
- [Troubleshooting](#troubleshooting)

---

## Is this pattern right for you

**Good fit:** internal or partner APIs that must not be publicly reachable; regulated workloads
needing network isolation; APIs with a known, governed set of callers; anywhere you need
centralized rate limiting and consistent auth policy.

**Consider something simpler if:** you need a genuinely public API with open registration; you're
prototyping; you have very high-volume, latency-critical traffic where an extra gateway hop
matters; or budget doesn't allow for an APIM Developer/Premium tier.

For the reasoning behind each design choice (why app roles instead of scopes, why APIM swaps the
token, why the backend still checks the caller's object ID, etc.), see
**[docs/security-architecture.md](docs/security-architecture.md)**.

---

## How a request flows

1. **The client acquires a token.** Delegated (Authorization Code + PKCE) for a signed-in user, or
   app-only (Client Credentials) for a daemon. Entra ID only issues a usable `roles` claim if the
   caller has been **assigned** the `Api.Access` app role.
2. **The client calls the APIM gateway** with two credentials:
   ```http
   GET https://your-apim.azure-api.net/yourapi/WeatherForecast
   Authorization: Bearer eyJ0eXAiOiJKV1Qi...
   Ocp-Apim-Subscription-Key: YOUR-KEY
   ```
   The token answers *"who are you and what may you do?"*; the subscription key answers *"which
   registered consumer is this, and what's its quota?"*.
3. **APIM validates the token** — signature, issuer, tenant, audience, expiry, and that `roles`
   contains `Api.Access`. Any failure returns `401` and the request is never forwarded.
4. **APIM discards the caller's token and mints its own:**
   ```xml
   <authentication-managed-identity resource="api://API-APP-ID"
       output-token-variable-name="apim-backend-token" ignore-error="false" />
   <set-header name="Authorization" exists-action="override">
     <value>@("Bearer " + (string)context.Variables["apim-backend-token"])</value>
   </set-header>
   ```
   APIM asks Entra ID for a token representing **itself**, then overwrites the `Authorization`
   header. The caller's token stops at the gateway.
5. **The request travels over the Private Endpoint.** DNS inside the VNet resolves the App
   Service to a private IP; public network access is disabled, so there's no other path.
6. **The API validates the token it received** — signature, issuer, tenant, audience, lifetime —
   then checks the `roles` claim contains `Api.Access` **and** the `oid` claim matches APIM's
   managed identity object ID. Any other caller gets `403`, even with an otherwise valid token.

---

## Implementing it yourself

Five parts, in order — later parts depend on identifiers produced by earlier ones.

### 1. The API project

**Install the package:**

```bash
dotnet add package Microsoft.Identity.Web
```

> `Microsoft.Identity.Web.Resource` is **not** a separate package in v4.x — it comes in
> transitively. Installing it directly fails with "no versions available."

**Configure authentication** (`Program.cs`):

```csharp
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

builder.Services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
{
    // CRITICAL — see the callout below.
    options.MapInboundClaims = false;

    options.TokenValidationParameters.ValidateIssuer = true;
    options.TokenValidationParameters.ValidIssuers = new[]
    {
        $"{instance}/{tenantId}/v2.0",          // v2 tokens
        $"https://sts.windows.net/{tenantId}/"  // v1 tokens
    };
    options.TokenValidationParameters.ValidateAudience = true;
    options.TokenValidationParameters.ValidateLifetime = true;
    options.TokenValidationParameters.ValidateIssuerSigningKey = true;
    options.TokenValidationParameters.RequireSignedTokens = true;
    options.TokenValidationParameters.RoleClaimType = "roles";
    options.TokenValidationParameters.NameClaimType = "name";
});
```

> **The `MapInboundClaims` trap.** It defaults to `true`, which rewrites `roles` to a legacy
> WS-Federation URI. If `RoleClaimType = "roles"` is also set, nothing matches and every
> `RequireRole()` fails silently with a bare `403`. Set `MapInboundClaims = false` to keep the
> original short claim names.

**Why list two issuers?** Client-credentials flows often return **v1** tokens even when the app
registration requests v2. Accepting both avoids an intermittent `401`.

**Add the authorization policy:**

```csharp
builder.Services.AddSingleton<IAuthorizationHandler, ApimManagedIdentityHandler>();
builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("ApiAccess", policy =>
    {
        policy.RequireAuthenticatedUser();
        policy.RequireRole(apiSecurity.RequiredAppRole);               // Api.Access
        policy.AddRequirements(new ApimManagedIdentityRequirement());  // oid must be APIM's
    });

    // Fail closed: a plain [Authorize] on a new controller inherits this policy.
    options.DefaultPolicy = options.GetPolicy("ApiAccess")!;
});
```

**Use strongly typed configuration with startup validation:**

```csharp
builder.Services
    .AddOptions<ApiSecurityOptions>()
    .Bind(builder.Configuration.GetSection(ApiSecurityOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();   // fail at startup, not on the first request
```

**Add security headers** — see `Middleware/SecurityHeadersMiddleware.cs`. Register it **first**:

```csharp
app.UseSecurityHeaders();   // before everything else
app.UseHttpsRedirection();
if (!app.Environment.IsDevelopment()) app.UseHsts();
app.UseCors("AllowApimGatewayOnly");
app.UseAuthentication();
app.UseAuthorization();
```

**appsettings.json:**

```json
{
  "AzureAd": {
    "Instance": "https://login.microsoftonline.com/",
    "TenantId": "YOUR-TENANT-ID",
    "ClientId": "API-APP-REGISTRATION-CLIENT-ID",
    "Audience": "api://API-APP-REGISTRATION-CLIENT-ID"
  },
  "ApiSecurity": {
    "RequiredAppRole": "Api.Access",
    "SwaggerClientId": "CLIENT-APP-REGISTRATION-CLIENT-ID",
    "AllowedManagedIdentityObjectId": "APIM-MANAGED-IDENTITY-OBJECT-ID",
    "EnforceManagedIdentityTrust": true,
    "AllowedOrigins": [ "https://YOUR-APIM.azure-api.net" ]
  }
}
```

In `appsettings.Development.json`, set `EnforceManagedIdentityTrust` to `false` to test locally
through Swagger with a user token, no APIM required.

In Azure, override the identity without redeploying via App Service app settings (double
underscore maps to the configuration colon separator) — useful because **recreating an APIM
instance produces a new managed identity object ID**:

```
ApiSecurity__AllowedManagedIdentityObjectId = APIM-MANAGED-IDENTITY-OBJECT-ID
ApiSecurity__EnforceManagedIdentityTrust    = true
```

### 2. Entra ID configuration

> Click-by-click portal instructions: **[Manual Azure Setup Guide, Parts 1-3](docs/manual-azure-setup.md)**

**API registration:**
1. Set the Application ID URI to `api://CLIENT-ID`. Do **not** define scopes.
2. Create the `Api.Access` app role with **Allowed member types = Both**.
3. Set `requestedAccessTokenVersion: 2` in the manifest.
4. On the enterprise application, set **Assignment required = Yes**.
5. Remove any self-referencing API permission.

> Token version 2 changes `aud` from `api://GUID` to the bare GUID. Your APIM policy must accept
> both forms or every call returns `401`.

**Client registration:**
1. Remove any Application ID URI and exposed scopes — it must be a pure client.
2. Add redirect URIs using the **Single-page application** platform (enforces PKCE).
3. Create a client secret only if it's a daemon — prefer certificates or Workload Identity
   Federation, and store secrets in Key Vault.
4. Add the delegated `Api.Access` permission and grant admin consent.

**Role assignments** — grant `Api.Access` to every calling principal:

| Principal | Assignment type | Needed for |
|-----------|-----------------|-----------|
| User or security group | User | Interactive callers (Swagger, a signed-in web app) |
| Client's service principal | **Application** | Daemon clients using client credentials |
| APIM's managed identity | **Application** | The APIM-to-backend hop |

> **Application assignments can't be made in the Azure Portal** — the *Users and groups* blade only
> accepts users and groups. Use [Graph Explorer](https://developer.microsoft.com/graph/graph-explorer):
> ```
> POST https://graph.microsoft.com/v1.0/servicePrincipals/API-ENTERPRISE-APP-OBJECT-ID/appRoleAssignedTo
> { "principalId": "CALLING-SP-OBJECT-ID", "resourceId": "API-ENTERPRISE-APP-OBJECT-ID", "appRoleId": "API-ACCESS-ROLE-ID" }
> ```
> A delegated permission is **not** a substitute — client credentials always requests `/.default`,
> and Entra ID populates `roles` in an app-only token exclusively from application role
> assignments. Skip this and the token arrives with no `roles` claim.

> **Application ID vs. Object ID.** Role assignments use Object IDs (from the enterprise
> application). Policies and token config use Application IDs (from the app registration).

### 3. API Management configuration

> Click-by-click portal instructions: **[Manual Azure Setup Guide, Parts 4-5](docs/manual-azure-setup.md)**

1. Create the instance — **Developer** for non-production, **Premium** for production.
2. Enable the system-assigned managed identity and record its Object ID.
3. Grant that identity the `Api.Access` role (Graph Explorer, as above).
4. Create the API, add operations, and add it to a product.
5. Apply the inbound policy:

```xml
<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="YOUR-TENANT-ID" header-name="Authorization"
        failed-validation-httpcode="401"
        failed-validation-error-message="Unauthorized: invalid or missing Entra ID token.">
      <client-application-ids>
        <application-id>CLIENT-APP-ID</application-id>
      </client-application-ids>
      <audiences>
        <!-- v1 tokens carry the Application ID URI; v2 carry the bare GUID. Accept both. -->
        <audience>api://API-APP-ID</audience>
        <audience>API-APP-ID</audience>
      </audiences>
      <required-claims>
        <claim name="roles" match="any"><value>Api.Access</value></claim>
      </required-claims>
    </validate-azure-ad-token>

    <authentication-managed-identity resource="api://API-APP-ID"
        output-token-variable-name="apim-backend-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["apim-backend-token"])</value>
    </set-header>
  </inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <set-header name="X-Powered-By" exists-action="delete" />
    <set-header name="X-AspNet-Version" exists-action="delete" />
    <set-header name="Server" exists-action="delete" />
  </outbound>
  <on-error><base /></on-error>
</policies>
```

Ready-to-use copies live in [`ApimSample.Api/apim-policies/`](ApimSample.Api/apim-policies/).

Notes: `ignore-error="false"` fails the request if token acquisition fails (instead of silently
forwarding with no `Authorization` header). `validate-azure-ad-token` is only valid at API or
operation scope, not global.

> **Choose the APIM tier carefully — the tier *type* can't be changed later** (Consumption <->
> dedicated tiers is unsupported). Also note Consumption and Basic/Standard v1 don't support VNet
> integration, so they can't reach a Private Endpoint. See
> [docs/security-architecture.md](docs/security-architecture.md#choosing-skus) for the SKU
> comparison.

### 4. Network isolation

> Click-by-click portal instructions: **[Manual Azure Setup Guide, Part 6](docs/manual-azure-setup.md)**

> **Order matters.** Build and verify the private path first, then disable public access. The
> reverse order takes your API offline.

1. **VNet** in the same region as APIM, with two subnets — one for APIM, one for private endpoints.
2. **NSG** on the APIM subnet. Port **3443** inbound from the `ApiManagement` service tag is
   mandatory (APIM reports unhealthy without it). Also allow `Internet` to 443 and
   `AzureLoadBalancer` to 6390.
3. **Join APIM to the VNet** in **External** mode (gateway stays public but gains VNet presence).
   Takes 30-45 minutes.
4. **Private Endpoint** for the App Service, with **Integrate with private DNS zone = Yes**.
5. **Verify** the path works through APIM.
6. **Disable public network access** on the App Service.

> Requires App Service Plan **Basic (B1) or higher** — unavailable on Free/Shared.

> **The private DNS zone must be linked to the VNet**, or APIM keeps resolving the public IP and
> the call breaks the moment public access is disabled. Verify under **Private DNS zone -> Virtual
> network links**.

### 5. Calling the API from a client

**Daemon / service-to-service (client credentials):**

```http
POST https://login.microsoftonline.com/TENANT/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id=CLIENT-APP-ID&client_secret=SECRET&scope=api://API-APP-ID/.default&grant_type=client_credentials
```

> The scope must reference the **API's** application ID, not the client's, or you get
> `AADSTS500011: The resource principal ... was not found in the tenant`.

Then call the gateway with both credentials:

```http
GET https://YOUR-APIM.azure-api.net/SUFFIX/WeatherForecast
Authorization: Bearer TOKEN
Ocp-Apim-Subscription-Key: KEY
```

**Interactive (Authorization Code + PKCE)** — Swagger UI configuration in `Program.cs`:

```csharp
app.UseSwaggerUI(c =>
{
    c.OAuthClientId(apiSecurity.SwaggerClientId);
    c.OAuthUsePkce();      // never use the implicit flow
});
```

**Client-side practices worth copying** (see `ApimSample.MvcClient/Services/TokenService.cs`):
cache tokens until near expiry with a safety buffer; guard acquisition with a `SemaphoreSlim` to
avoid a stampede; keep secrets in `dotnet user-secrets` locally and Key Vault in Azure.

---

## Reference: this repository

| Project | Role |
|---------|------|
| **ApimSample.Api** | The zero-trust API — Entra ID App Roles, Microsoft.Identity.Web, managed-identity trust, security headers. The reference implementation. |
| **ApimSample.MvcClient** | Sample client — acquires a token via client credentials and calls the API through APIM. |
| **ApimSample.ApimSecuredApi** | Contrast case — a backend with no auth code, where APIM does everything. Simpler, weaker (no defense in depth if APIM is bypassed). |

| File | What it does |
|------|--------------|
| [ApimSample.Api/Program.cs](ApimSample.Api/Program.cs) | Auth wiring, token validation, the `ApiAccess` policy, Swagger OAuth, middleware order |
| [ApimSample.Api/Authorization/ApimManagedIdentityRequirement.cs](ApimSample.Api/Authorization/ApimManagedIdentityRequirement.cs) | The `oid` check |
| [ApimSample.Api/Options/ApiSecurityOptions.cs](ApimSample.Api/Options/ApiSecurityOptions.cs) | Strongly typed, startup-validated security configuration |
| [ApimSample.Api/Middleware/SecurityHeadersMiddleware.cs](ApimSample.Api/Middleware/SecurityHeadersMiddleware.cs) | HSTS, CSP, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy |
| [ApimSample.Api/apim-policies/](ApimSample.Api/apim-policies/) | The APIM policies, standalone and combined |
| [ApimSample.MvcClient/Services/TokenService.cs](ApimSample.MvcClient/Services/TokenService.cs) | Token acquisition with caching and thread safety |

### Running locally

```bash
# API — local dev disables managed-identity trust so you can use a user token
cd ApimSample.Api
dotnet run
# Browse to /swagger, authorize, call an endpoint

# Client — supply secrets out-of-band, never in appsettings.json
cd ApimSample.MvcClient
dotnet user-secrets set "AzureAd:ClientSecret"        "YOUR-CLIENT-SECRET"
dotnet user-secrets set "ApiSettings:SubscriptionKey" "YOUR-APIM-SUBSCRIPTION-KEY"
dotnet run
```

---

## Testing and verification

| Test | Expected | Proves |
|------|----------|--------|
| Call the gateway with a valid token + subscription key | **200** | The whole chain works |
| Call the gateway without a token | **401** | `validate-azure-ad-token` is active |
| Call the gateway without a subscription key | **401** | The product requires a subscription |
| Call with a token lacking `Api.Access` | **401** | Role enforcement is active |
| Call with a token for a different audience | **401** | Audience validation is active |
| Call the App Service hostname directly with a valid token | **403** | The backend trusts only APIM |
| Same, after disabling public access | **403** from Azure networking, before your code runs | Network isolation |

The second-to-last test is the important one — if a direct call with a valid token succeeds,
check `EnforceManagedIdentityTrust` and that `MapInboundClaims = false`.

**Inspect a token** at [jwt.ms](https://jwt.ms): `aud` should be the API's app ID (v2) or
`api://APP-ID` (v1); `iss` should match your tenant; `roles` should contain `Api.Access`; for the
APIM hop, `oid` should be APIM's managed identity object ID. Only decode non-production tokens.

**Trace a request in APIM:** open the API -> **Test** tab -> send a request -> **Trace** tab shows
exactly which policy rejected the call.

---

## Troubleshooting

**Read the status code first:** `401` means the token was rejected (signature, issuer, tenant,
audience, expiry). `403` means the token was valid but the caller isn't permitted (`roles`, `oid`,
authorization policy).

| Symptom | Cause | Fix |
|---------|-------|-----|
| `401` at APIM | Token `aud` doesn't match the policy | Token version 2 means `aud` is the bare GUID — add it as a second `audience` entry |
| `AADSTS500011` requesting a token | Wrong resource in the scope | Use `api://API-APP-ID/.default` — the API's ID, not the client's |
| Token has no `roles` claim | Missing *application* app role assignment | Assign via Graph Explorer — delegated permissions don't populate `roles` |
| `403` from the backend with a valid token | `oid` mismatch, or `roles` not being read | Check `AllowedManagedIdentityObjectId`; ensure `MapInboundClaims = false` |
| `403` calling the App Service directly | Working as designed | This is the zero-trust behavior |
| `500`/timeout through APIM after disabling public access | Private DNS zone not linked to the VNet | Check **Private DNS zone -> Virtual network links** |
| APIM unhealthy after joining the VNet | NSG blocks port 3443 | Allow inbound from the `ApiManagement` service tag to 3443 |
| `Policy scope is not allowed in this section` | Policy at the wrong scope | `validate-azure-ad-token` belongs at API/operation scope, not global |
| Auth breaks with no config change | Client secret expired | Rotate it; set an expiry alert |
| Can't deploy any more | Public access disabled | Deploy from inside the VNet or add an SCM access restriction |

**Tooling gotchas:** `az apim api policy` doesn't exist — use the ARM REST API instead
(`PUT .../apis/API-ID/policies/policy`). `az rest` can fail with a charmap codec error on APIM
responses (BOM) — use `curl.exe` with a bearer token from `az account get-access-token`.

---

## Learn more

- **[docs/security-architecture.md](docs/security-architecture.md)** — design rationale, recommendation
  levels, production hardening checklist, and Microsoft Learn references
- **[infra/README.md](infra/README.md)** — automated Bicep + PowerShell deployment
- **[docs/manual-azure-setup.md](docs/manual-azure-setup.md)** — portal-only setup guide