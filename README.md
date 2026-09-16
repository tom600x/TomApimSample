# Zero-Trust API Security with Azure API Management and Microsoft Entra ID

A reference implementation and guide for protecting an ASP.NET Core API so that it is reachable **only** through
Azure API Management, and only by callers your organization has explicitly authorized.

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

> **New here?** Read [Why this pattern](#why-this-pattern) then [How a request flows](#how-a-request-flows) then
> [Implementing it yourself](#implementing-it-yourself).
>
> **Need to build the Azure resources by hand?** See the
> **[Manual Azure Setup Guide](docs/manual-azure-setup.md)** - click-by-click portal instructions with no CLI or
> IaC, written for cloud teams that require manual, reviewable changes.

---

## Table of contents

- [Why this pattern](#why-this-pattern)
- [How a request flows](#how-a-request-flows)
- [The seven layers of defense](#the-seven-layers-of-defense)
- [Key design decisions explained](#key-design-decisions-explained)
- [Implementing it yourself](#implementing-it-yourself)
- [Reference: this repository](#reference-this-repository)
- [Testing and verification](#testing-and-verification)
- [Troubleshooting](#troubleshooting)
- [Adapting the pattern](#adapting-the-pattern)
- [Further reading](#further-reading)

---

## Why this pattern

Most API security guidance stops at "validate the JWT." That protects you from *unauthenticated* callers, but it
leaves several real problems unsolved:

| Problem | What "just validate the JWT" does | What this pattern does |
|---------|-----------------------------------|------------------------|
| Your App Service has a public hostname anyone can find and probe | Nothing - the endpoint is still reachable and still burns CPU rejecting requests | Public network access is **disabled**; there is no route to the backend except through APIM |
| A leaked or replayed caller token can be used against the backend directly | Nothing - the token is valid, so the backend accepts it | The caller's token **never reaches the backend**; APIM substitutes its own |
| Any app in your tenant can request a token for your API | Nothing by default - tokens are issued to anyone who asks | **Assignment required** plus app roles mean Entra ID refuses to issue a usable token to unapproved principals |
| You cannot tell *which* application is calling, only which user | Weak - user identity only | Subscription keys identify the calling application; app role assignments constrain it |
| Rate limiting, quotas, and WAF live in your application code | You write and maintain them | The gateway and WAF handle them before traffic reaches you |

The goal is **assumed breach**. Every layer is designed so that the failure of any *other* layer is not
catastrophic. If someone mistakenly re-enables public network access, the application still rejects non-APIM
callers. If an app role were granted too widely, the network layer still blocks direct access.

### When to use this pattern

**Good fit:**
- Internal or partner APIs that must not be publicly reachable
- Regulated workloads (finance, healthcare, government) with network isolation requirements
- APIs where the set of authorized callers is known and governed
- Anywhere you need centralized rate limiting, quotas, and consistent authentication policy

**Poor fit - consider something simpler:**
- A genuinely public API with open registration (the assignment-required model fights you)
- Prototypes and internal demos (the operational overhead is real)
- Very high-volume, latency-critical traffic where an extra gateway hop matters
- Budget-constrained projects - APIM Developer tier is not free, and Premium is substantially more

---

## How a request flows

Walking through a single request makes the design click.

**1. The client acquires a token**

The client authenticates to Microsoft Entra ID and requests a token for the API. Either:
- *Delegated* (a user is present): Authorization Code + PKCE. The token represents **the user**.
- *App-only* (a daemon or service): Client Credentials. The token represents **the application**.

Entra ID checks whether the caller has been **assigned** the `Api.Access` app role. If not, it issues a token
with no `roles` claim - or refuses entirely. This is the first gate, and it happens before your infrastructure
sees anything.

**2. The client calls the APIM gateway**

```http
GET https://your-apim.azure-api.net/yourapi/WeatherForecast
Authorization: Bearer eyJ0eXAiOiJKV1Qi...
Ocp-Apim-Subscription-Key: YOUR-KEY
```

Note there are **two** credentials. The token answers *"who are you and what may you do?"*. The subscription key
answers *"which registered consumer application is this, and what is its quota?"*.

**3. APIM validates the token**

The `validate-azure-ad-token` policy checks the signature against Entra ID's published keys, the issuer, the
tenant, the expiry, the audience, that the calling application is on the allow-list, and that the `roles` claim
contains `Api.Access`. Any failure returns `401` and **the request is never forwarded**. Your backend never sees
bad traffic.

**4. APIM discards the caller's token and mints its own**

This is the crucial step, and the one most implementations miss:

```xml
<authentication-managed-identity resource="api://API-APP-ID"
    output-token-variable-name="apim-backend-token" ignore-error="false" />
<set-header name="Authorization" exists-action="override">
  <value>@("Bearer " + (string)context.Variables["apim-backend-token"])</value>
</set-header>
```

APIM asks Entra ID for a **brand-new token representing APIM itself**, then **overwrites** the `Authorization`
header. The caller's token stops at the gateway.

**5. The request travels over the Private Endpoint**

DNS inside the virtual network resolves the App Service hostname to a private IP (for example `10.10.2.4`). The
traffic never touches the public internet. Simultaneously, public network access on the App Service is
**disabled**, so there is no alternative path.

**6. The API validates the token it received**

ASP.NET Core validates signature, issuer, tenant, audience, and lifetime - then applies authorization:

- Does the token carry the `Api.Access` role? (It does - APIM's managed identity was granted it.)
- Does the token's `oid` claim match the APIM managed identity's object ID? (It does.)

Any other caller - even one holding a perfectly valid token with the right role - fails the `oid` check and gets
`403`.

---

## The seven layers of defense

| # | Layer | Control | What it stops | Where it is configured |
|---|-------|---------|---------------|----------------------|
| 1 | Edge | Front Door WAF + `X-Azure-FDID` check | OWASP-class attacks, DDoS, WAF bypass | Front Door + APIM global policy |
| 2 | Identity | Entra ID issues tokens only to assigned principals | Unapproved apps and users, tenant-wide | App registration, *Assignment required* |
| 3 | Gateway auth | `validate-azure-ad-token` | Forged, expired, foreign-tenant, wrong-audience tokens | APIM inbound policy |
| 4 | Consumer mgmt | Product + subscription key | Unattributable and unmetered consumption | APIM product |
| 5 | Token exchange | `authentication-managed-identity` | Token replay against the backend; confused deputy | APIM inbound policy |
| 6 | Application | `oid` must equal APIM's identity | Any caller that is not APIM | `ApimManagedIdentityRequirement.cs` |
| 7 | Network | Private Endpoint; public access disabled | Every direct network route to the backend | App Service networking |

Layers 5, 6, and 7 are what distinguish this from ordinary "API behind a gateway" setups. Layers 6 and 7 in
particular are redundant with each other **on purpose**.

---

## Key design decisions explained

### Why App Roles instead of scopes

Entra ID offers two authorization primitives, and the difference is not cosmetic:

| | **Scopes** (`scp` claim) | **App Roles** (`roles` claim) |
|---|---|---|
| Semantic meaning | "This app may act **on behalf of a signed-in user**" | "This principal is **granted** this permission" |
| Requires a user | Yes - delegated flows only | No - works with users *and* applications |
| Works with client credentials | No | Yes |
| Works with managed identities | No | Yes |
| Can be consented by the user | Often yes | No - admin assignment only |

The decisive constraint: **APIM's managed identity has no user.** Its call to the backend is app-only, so it can
never present a `scp` claim. If the API required scopes, the APIM hop could not be authorized at all.

App roles also fail *closed*. Combined with **Assignment required = Yes**, a principal that has not been
explicitly granted the role receives a token without the `roles` claim, and every check downstream rejects it.

In this implementation the role is `Api.Access`, with **Allowed member types = Both**, so it can be assigned to
users (for interactive Swagger testing) *and* applications (for APIM and daemon clients).

### Why APIM swaps the token instead of forwarding it

The naive approach forwards the caller's `Authorization` header to the backend. It works, and it is wrong for
three reasons:

1. **Token replay.** A token valid at the backend is a bearer credential. If it leaks - from a log, a crash dump,
   a compromised client - anyone who can reach the backend can use it. Swapping the token means the caller's
   credential is only ever valid at the gateway.

2. **The confused deputy problem.** If the backend accepts caller tokens, it must independently re-derive what
   each caller is allowed to do, duplicating the gateway's logic. Divergence between the two is where
   vulnerabilities appear. With the swap, the backend answers one simple question: *"Are you APIM?"*

3. **A clean trust boundary.** The gateway owns "is this caller authorized?" The backend owns "did this come from
   the gateway?" Each has one job, and each is easy to reason about and audit.

> If the backend needs to know *who the original user was* (for auditing or per-user data), do not revert to
> forwarding the token. Instead have APIM extract the relevant claims and pass them in a separate signed header,
> or use an `on-behalf-of` flow. Keep the *authorization* decision at the gateway.

### Why the API checks the caller's object ID

Validating the token proves it came from Entra ID and carries `Api.Access`. It does **not** prove it came from
APIM. Any principal assigned that role could mint an equally valid token.

So the API adds one more check:

```csharp
// Authorization/ApimManagedIdentityRequirement.cs
var oid = context.User.FindFirst("oid")?.Value;
if (!string.Equals(oid, options.AllowedManagedIdentityObjectId, StringComparison.OrdinalIgnoreCase))
{
    // Valid token, correct role - but not APIM. Requirement not satisfied, so 403.
    return Task.CompletedTask;
}
```

The `oid` (object ID) claim identifies the *specific* service principal the token was issued to. Pinning it to
APIM's managed identity means the API accepts requests from exactly one caller in the entire tenant.

This is the application-layer twin of the Private Endpoint. Network isolation stops packets; this stops tokens.
Either alone is good; together the backend is protected even if one is misconfigured.

The check is toggleable via `ApiSecurity:EnforceManagedIdentityTrust` so developers can run and debug locally
without an APIM instance.

### Why two app registrations

A common shortcut is to use one app registration for everything. Separate them:

| | **API registration** | **Client registration** |
|---|---|---|
| Represents | The protected resource | The application calling it |
| Application ID URI | `api://GUID` | none |
| App roles | defines `Api.Access` | none |
| Redirect URIs | none | yes, for interactive flows |
| Client secret | none | only if it is a daemon |
| Requests tokens | never | always |

Why it matters:

- **Least privilege and blast radius.** The API registration holds no credentials at all, so there is nothing to
  leak. A compromised client secret affects one client, not the resource definition.
- **Independent lifecycles.** You can rotate a client secret, add a redirect URI, or retire a client entirely
  without touching the resource that defines your permissions.
- **Multiple clients.** A second client (mobile app, partner integration) is a new registration granted the same
  role. With a single registration this becomes tangled quickly.
- **Auditability.** "Who can call this API?" is answered by one list: the role assignments on the API's
  enterprise application.

A registration that both exposes an API and requests tokens for itself is a configuration smell. If you see a
self-referencing entry under **API permissions**, remove it.

### Why a subscription key and a token

They answer different questions and are not redundant:

- The **OAuth token** is a *security* control. It is cryptographically signed, short-lived, carries identity and
  authorization claims, and cannot be forged.
- The **subscription key** is an *API product management* control. It is a long-lived shared secret that
  identifies a registered consumer so APIM can apply rate limits, quotas, per-consumer analytics, and revoke one
  consumer's access without affecting others.

> **Never treat a subscription key as a security boundary.** It is a static string, frequently embedded in
> client apps, and does not expire on its own. It is for *metering and management*. The token does the security.

### Why the Private Endpoint is still needed

Given layer 6 already rejects non-APIM callers with `403`, why bother with network isolation?

- **Defense in depth.** A future code change, a misconfigured app setting, or a rolled-back deployment could
  weaken the application check. The network layer is independent of your code.
- **Attack surface reduction.** A publicly reachable App Service can be scanned, fingerprinted, and probed for
  platform vulnerabilities - problems that exist *below* your authentication code.
- **Resource exhaustion.** Rejecting a request still costs CPU, TLS handshakes, and log volume. A closed network
  path costs nothing.
- **Compliance.** Many regulatory frameworks mandate network-level isolation regardless of application controls.

Concretely: before network isolation a direct call returns `403` (your code rejected it). After, it returns `403`
from the Azure networking layer - your code never runs.

> **Disabling public access also disables Kudu/SCM, log streaming, and portal deployment.** Plan your deployment
> path - a build agent inside the VNet, a self-hosted runner, or a narrowly scoped access restriction for the SCM
> site - *before* you flip that switch.
---

## Implementing it yourself

Five parts. Do them in this order; later parts depend on identifiers produced by earlier ones.

### 1. The API project

**Install the package:**

```bash
dotnet add package Microsoft.Identity.Web
```

> `Microsoft.Identity.Web.Resource` is **not** a separate package in v4.x - it comes in transitively. Trying to
> install it fails with "no versions available."

**Configure authentication** (`Program.cs`):

```csharp
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

builder.Services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
{
    // CRITICAL - see the warning below.
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

> ### The MapInboundClaims trap
>
> `JwtBearerOptions.MapInboundClaims` defaults to `true`, which rewrites inbound JWT claim types to legacy
> WS-Federation URIs - `roles` becomes
> `http://schemas.microsoft.com/ws/2008/06/identity/claims/role`. If you then set `RoleClaimType = "roles"`, it
> matches **nothing**, and every `RequireRole()` check fails silently with a bare `403` and no logged error. The
> same applies to the `oid` lookup.
>
> Setting `MapInboundClaims = false` keeps the original short claim names. This one line is the difference
> between a working API and hours of debugging.

**Why list two issuers?** Client-credentials flows often return **v1** tokens
(`iss` = `https://sts.windows.net/TENANT/`) even when the app registration requests v2. Accepting both avoids an
intermittent, confusing `401`.

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

    // Fail closed: anything decorated with [Authorize] gets this policy by default.
    options.DefaultPolicy = options.GetPolicy("ApiAccess")!;
});
```

Setting `DefaultPolicy` matters. A developer who writes a plain `[Authorize]` on a new controller automatically
inherits the full policy rather than the weaker "any authenticated caller" default.

**Use strongly typed configuration with startup validation:**

```csharp
builder.Services
    .AddOptions<ApiSecurityOptions>()
    .Bind(builder.Configuration.GetSection(ApiSecurityOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();   // fail at startup, not on the first request
```

`ValidateOnStart()` turns a missing object ID into a startup crash with a clear message instead of a mysterious
runtime `403`. For security configuration, failing loudly at deploy time is always better.

**Add security headers** - see `Middleware/SecurityHeadersMiddleware.cs`. Register it **first** so headers apply
to error responses too:

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

In `appsettings.Development.json`, set `EnforceManagedIdentityTrust` to `false` so you can test locally through
Swagger with a user token - no APIM required.

In Azure, override the identity without redeploying by using App Service app settings (double underscore maps to
the configuration colon separator):

```
ApiSecurity__AllowedManagedIdentityObjectId = APIM-MANAGED-IDENTITY-OBJECT-ID
ApiSecurity__EnforceManagedIdentityTrust    = true
```

This is genuinely useful, because **recreating an APIM instance produces a new managed identity object ID**.

### 2. Entra ID configuration

> Full click-by-click portal instructions: **[Manual Azure Setup Guide, Parts 1-3](docs/manual-azure-setup.md)**

**API registration:**
1. Set the Application ID URI to `api://CLIENT-ID`. Do **not** define scopes.
2. Create the `Api.Access` app role with **Allowed member types = Both**.
3. Set `requestedAccessTokenVersion: 2` in the manifest.
4. On the **enterprise application**, set **Assignment required = Yes**.
5. Remove any self-referencing API permission.

> Setting token version to 2 changes `aud` from `api://GUID` to the **bare GUID**. Your APIM policy must accept
> both forms or every call returns `401`.

**Client registration:**
1. Remove any Application ID URI and exposed scopes - it must be a pure client.
2. Add redirect URIs using the **Single-page application** platform (enforces PKCE). Never enable implicit grant.
3. Create a client secret only if it is a daemon - prefer certificates or Workload Identity Federation, and store
   secrets in Key Vault.
4. Add the **delegated** `Api.Access` permission and grant admin consent (for interactive callers).

**Role assignments** - grant `Api.Access` to every calling principal:

| Principal | Assignment type | Needed for |
|-----------|-----------------|-----------|
| User or security group | User | Interactive callers (Swagger, a web app with sign-in) |
| Client's service principal | **Application** | Daemon clients using client credentials |
| APIM's managed identity | **Application** | The APIM to backend hop |

> **Application assignments cannot be made in the Azure Portal.** The *Users and groups* blade only accepts users
> and groups. Use **[Graph Explorer](https://developer.microsoft.com/graph/graph-explorer)**:
>
> ```
> POST https://graph.microsoft.com/v1.0/servicePrincipals/API-ENTERPRISE-APP-OBJECT-ID/appRoleAssignedTo
>
> { "principalId": "CALLING-SP-OBJECT-ID",
>   "resourceId":  "API-ENTERPRISE-APP-OBJECT-ID",
>   "appRoleId":   "API-ACCESS-ROLE-ID" }
> ```
>
> **A delegated permission is not a substitute.** Client credentials always requests `/.default`, and Entra ID
> populates `roles` in an app-only token *exclusively* from application role assignments. Skip this and your token
> arrives with **no roles claim** - the most common failure in this whole setup.

> **Application ID vs. Object ID.** Role assignments use **Object IDs** (from the *enterprise application*).
> Policies and token config use **Application IDs** (from the *app registration*). Mixing them up is the single
> most common mistake.
### 3. API Management configuration

> Full click-by-click portal instructions: **[Manual Azure Setup Guide, Parts 4-5](docs/manual-azure-setup.md)**

1. Create the instance. **Developer** for non-production, **Premium** for production.
2. Enable the **system-assigned managed identity** and record its Object ID.
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

**Policy details worth understanding:**

- `ignore-error="false"` - if token acquisition fails, fail the request. With `true`, APIM would forward the call
  with **no** `Authorization` header, turning a clean failure into a baffling one.
- `client-application-ids` - an allow-list of calling apps, enforced *in addition to* role assignment.
- `validate-azure-ad-token` is valid at **API or operation** scope. At global scope it errors with
  `Policy scope is not allowed in this section`.
- Stripping `Server` and `X-Powered-By` on the way out avoids leaking backend implementation details.

> **Choose the APIM tier carefully - tier *type* cannot be changed later.** Moving between Consumption and the
> dedicated tiers is unsupported (`ChangingSkuTypeNotSupported`). The only route is delete, then **purge** the
> soft-deleted record to free the name, then recreate - losing every API, product, policy, subscription key,
> **and the managed identity**. Also note Consumption and Basic/Standard v1 **do not support VNet integration**,
> so they cannot reach a Private Endpoint.

### 4. Network isolation

> Full click-by-click portal instructions: **[Manual Azure Setup Guide, Part 6](docs/manual-azure-setup.md)**

> **Order matters.** Build and verify the private path *first*, then disable public access. The reverse order
> takes your API offline.

1. **VNet** in the same region as APIM, with two subnets: one dedicated to APIM, one for private endpoints.
2. **NSG** on the APIM subnet. Port **3443** inbound from the `ApiManagement` service tag is **mandatory** -
   without it APIM is reported unhealthy and stops receiving configuration. Also allow `Internet` to 443
   (External mode) and `AzureLoadBalancer` to 6390.
3. **Join APIM to the VNet** in **External** mode - the gateway stays publicly reachable but gains a presence
   inside the VNet so it can reach private resources. (*Internal* mode makes the gateway itself private; use it
   only when something else fronts APIM.) Takes 30-45 minutes.
4. **Private Endpoint** for the App Service in the private-endpoint subnet, with **Integrate with private DNS
   zone = Yes**.
5. **Verify** the path works through APIM.
6. **Disable public network access** on the App Service.

> **Requires Basic (B1) or higher.** Private Endpoints and "disable public access" are unavailable on Free (F1)
> and Shared (D1) App Service Plans.

> **The private DNS zone must be linked to the VNet.** An unlinked zone resolves nothing, APIM keeps resolving
> the public IP, and the call breaks the moment you disable public access. This is the most common cause of a
> Private Endpoint that "exists but does not work." Verify under **Private DNS zone, Virtual network links**.

### 5. Calling the API from a client

**Daemon / service-to-service (client credentials):**

```http
POST https://login.microsoftonline.com/TENANT/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id=CLIENT-APP-ID
&client_secret=SECRET
&scope=api://API-APP-ID/.default
&grant_type=client_credentials
```

> The scope must reference the **API's** application ID, not the client's. Getting this wrong produces
> `AADSTS500011: The resource principal named api://... was not found in the tenant` - a misleading message that
> suggests a missing app rather than a wrong identifier.

Then call the gateway with **both** credentials:

```http
GET https://YOUR-APIM.azure-api.net/SUFFIX/WeatherForecast
Authorization: Bearer TOKEN
Ocp-Apim-Subscription-Key: KEY
```

**Interactive (Authorization Code + PKCE)** - the Swagger UI configuration in `Program.cs`:

```csharp
app.UseSwaggerUI(c =>
{
    c.OAuthClientId(apiSecurity.SwaggerClientId);
    c.OAuthUsePkce();      // never use the implicit flow
});
```

**Client-side practices worth copying** (see `ApimSample.MvcClient/Services/TokenService.cs`):
- Cache tokens until near expiry with a safety buffer (5 minutes). Requesting a token per call is slow and will
  get you throttled.
- Guard acquisition with a `SemaphoreSlim` so a burst of requests does not trigger a stampede.
- Keep secrets in `dotnet user-secrets` locally and Key Vault in Azure - never in `appsettings.json`.

---

## Reference: this repository

A working implementation of everything above.

| Project | Role |
|---------|------|
| **ApimSample.Api** | The zero-trust API. Entra ID App Roles, Microsoft.Identity.Web, managed-identity trust, security headers. **This is the reference implementation.** |
| **ApimSample.MvcClient** | Sample client. Acquires a token via client credentials and calls the API through APIM. |
| **ApimSample.ApimSecuredApi** | Contrast case: a backend with *no* auth code, where APIM does everything. Simpler, weaker - no defense in depth if APIM is bypassed. |

### Files that implement the pattern

| File | What it does |
|------|--------------|
| [ApimSample.Api/Program.cs](ApimSample.Api/Program.cs) | Auth wiring, explicit token validation, the `ApiAccess` policy, Swagger OAuth, middleware order. **Contains the `MapInboundClaims = false` fix.** |
| [ApimSample.Api/Authorization/ApimManagedIdentityRequirement.cs](ApimSample.Api/Authorization/ApimManagedIdentityRequirement.cs) | The `oid` check - application-layer half of the zero-trust guarantee |
| [ApimSample.Api/Options/ApiSecurityOptions.cs](ApimSample.Api/Options/ApiSecurityOptions.cs) | Strongly typed, startup-validated security configuration |
| [ApimSample.Api/Middleware/SecurityHeadersMiddleware.cs](ApimSample.Api/Middleware/SecurityHeadersMiddleware.cs) | HSTS, CSP, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy |
| [ApimSample.Api/apim-policies/](ApimSample.Api/apim-policies/) | The APIM policies, standalone and combined |
| [ApimSample.MvcClient/Services/TokenService.cs](ApimSample.MvcClient/Services/TokenService.cs) | Token acquisition with caching and thread safety |

### Running locally

```bash
# API - local dev disables managed-identity trust so you can use a user token
cd ApimSample.Api
dotnet run
# Browse to /swagger, authorize, call an endpoint

# Client - supply secrets out-of-band, never in appsettings.json
cd ApimSample.MvcClient
dotnet user-secrets set "AzureAd:ClientSecret"        "YOUR-CLIENT-SECRET"
dotnet user-secrets set "ApiSettings:SubscriptionKey" "YOUR-APIM-SUBSCRIPTION-KEY"
dotnet run
```

> Check for a stale `appsettings.Development.json`. An old copy overriding `BaseUrl`, `Scope`, or `ClientSecret`
> will override your real settings and produce confusing auth failures. It should contain logging configuration
> only.
---

## Testing and verification

Verify each layer independently - a test that only exercises the happy path proves very little.

| Test | Expected | Proves |
|------|----------|--------|
| Call the gateway with a valid token + subscription key | **200** | The whole chain works |
| Call the gateway **without** a token | **401** | `validate-azure-ad-token` is active |
| Call the gateway **without** a subscription key | **401** | The product requires a subscription |
| Call with a token lacking `Api.Access` | **401** | Role enforcement is active |
| Call with a token for a different audience | **401** | Audience validation is active |
| Call the **App Service hostname directly** with a valid token | **403** | The backend trusts only APIM (layer 6) |
| Same, after disabling public access | **403** from Azure networking; request never reaches your code | Network isolation (layer 7) |

That second-to-last test is the important one. If a direct call with a valid token succeeds, your managed-identity
trust check is not working - verify `EnforceManagedIdentityTrust` and that `MapInboundClaims = false`.

**Inspect a token** at [jwt.ms](https://jwt.ms):

| Claim | Should be |
|-------|-----------|
| `aud` | the API's app ID (v2) or `api://APP-ID` (v1) |
| `iss` | `https://login.microsoftonline.com/TENANT/v2.0` or `https://sts.windows.net/TENANT/` |
| `tid` | your tenant ID |
| `roles` | contains `Api.Access` |
| `oid` | for the APIM hop, APIM's managed identity object ID |

> Only decode **non-production** tokens, and treat any token as a live credential until it expires.

**Trace a request in APIM:** open the API, go to the **Test** tab, send a request, then open the **Trace** tab. It
shows exactly which policy rejected the call and why - far faster than inferring from a status code.

---

## Troubleshooting

### Read the status code first

This single distinction will save you hours:

- **401 Unauthorized** - the token was **rejected**. Look at signature, issuer, tenant, audience, expiry.
- **403 Forbidden** - the token was **valid**, but the caller is not permitted. Look at `roles`, `oid`, and your
  authorization policy.

### Common failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `401` at APIM | Token `aud` does not match the policy | You set token version 2, so `aud` is the bare GUID. Add it as a second `audience` entry. |
| `AADSTS500011` when requesting a token | Wrong resource in the scope | Use `api://API-APP-ID/.default` - the **API's** ID, not the client's. |
| Token has **no** `roles` claim | Missing *application* app role assignment | Assign via Graph Explorer. Delegated permissions do not populate `roles`. |
| `403` from the backend with a valid token | `oid` mismatch, or `roles` not being read | Check `AllowedManagedIdentityObjectId`; ensure `options.MapInboundClaims = false`. |
| `403` calling the App Service directly | Working as designed | This is the zero-trust behaviour. |
| `500` or timeout through APIM after disabling public access | Private DNS zone not linked to the VNet | Check **Private DNS zone, Virtual network links**. |
| APIM unhealthy after joining the VNet | NSG blocks port 3443 | Add inbound Allow from the `ApiManagement` service tag to 3443. |
| `Policy scope is not allowed in this section` | Policy at the wrong scope | `validate-azure-ad-token` belongs at API or operation scope, not global. |
| Auth breaks suddenly with no config change | Client secret expired | Rotate it; set an expiry alert. |
| Cannot deploy any more | Public access disabled | Deploy from inside the VNet or add an SCM access restriction. |

### Tooling gotchas

- **`az apim api policy` does not exist.** Use the ARM REST API:
  `PUT .../apis/API-ID/policies/policy?api-version=2022-08-01` with
  `{"properties":{"format":"rawxml","value":"..."}}`.
- **`az rest` fails with a charmap codec error** on APIM responses (they include a BOM). Use `curl.exe` with a
  bearer token from `az account get-access-token`, and write JSON bodies **without** a BOM.
- **`Microsoft.Identity.Web.Resource` is not a standalone package** in v4.x.

---

## Adapting the pattern

| Your situation | Change |
|----------------|--------|
| Multiple permission levels | Define several app roles (`Api.Read`, `Api.Write`) and add a policy per role. The APIM `required-claims` block accepts multiple values. |
| Multiple client apps | One registration per client, each granted the appropriate role. Add each to `client-application-ids`. |
| Backend needs the original user identity | Have APIM extract claims into signed headers, or use `on-behalf-of`. **Do not** revert to forwarding the caller's token. |
| Backend is not App Service | The pattern is unchanged. Container Apps, AKS, and Functions all support Private Endpoints and token validation. |
| Multi-region | APIM Premium multi-region, a Private Endpoint per region, Front Door for routing. |
| Non-Azure or on-prem backend | Keep layers 1-5. Replace the Private Endpoint with ExpressRoute/VPN plus the APIM self-hosted gateway. |
| Cannot use APIM | Application Gateway + WAF can front the API, but you lose the managed-identity token swap - the backend must then validate caller tokens directly. |

### Production readiness checklist

| Item | Why |
|------|-----|
| Diagnostic logs to Log Analytics (APIM **and** App Service) | You cannot investigate a `401` or `403` after the fact without them |
| Application Insights on APIM | End-to-end correlation across the gateway hop |
| Rate limiting and quotas on products | Protects the backend from abuse |
| Secrets in Key Vault, not app settings | Centralized rotation and audit |
| Alerts on client secret expiry | Expired secrets fail with no prior warning |
| Conditional Access on the API | MFA or compliant device for interactive callers |
| Quarterly access reviews on role assignments | Catches stale access |
| Disable Swagger in production, or restrict it | Do not publish your schema publicly |
| Microsoft Defender for APIs | Detects anomalous traffic |
| Least-privilege RBAC (avoid Owner) | Limits blast radius |

> Note that **no Azure RBAC role** establishes the APIM-to-backend trust. That is entirely an Entra ID app role
> assignment plus the API's own authorization policy. RBAC governs who can *administer* these resources, not who
> can *call* the API.

---

## Further reading

- [Microsoft.Identity.Web documentation](https://learn.microsoft.com/entra/msal/dotnet/microsoft-identity-web/)
- [Entra ID app roles](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps)
- [APIM validate-azure-ad-token policy](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy)
- [APIM authentication-managed-identity policy](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [APIM VNet integration](https://learn.microsoft.com/azure/api-management/virtual-network-concepts)
- [App Service Private Endpoints](https://learn.microsoft.com/azure/app-service/networking/private-endpoint)
- [Azure Well-Architected Framework - Security](https://learn.microsoft.com/azure/well-architected/security/)
- [Microsoft Zero Trust guidance](https://learn.microsoft.com/security/zero-trust/)