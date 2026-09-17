# Security Architecture and Design Rationale

This document explains **why** the pattern in this repo is built the way it is — the recommendation
level of each control and the trade-off it addresses. For the practical setup steps, see the
[main README](../README.md). For portal click-through, see the
[Manual Azure Setup Guide](manual-azure-setup.md).

## Layers of defense

| # | Layer | Control | Recommendation | Stops |
|---|-------|---------|-----------------|-------|
| 1 | Edge | Front Door WAF | Recommended for internet-facing APIs | OWASP-class attacks, DDoS |
| 2 | Identity | Entra ID issues tokens only to assigned principals | **Required** | Unapproved apps/users tenant-wide |
| 3 | Gateway auth | `validate-azure-ad-token` | **Required** | Forged, expired, wrong-tenant/audience tokens |
| 4 | Consumer mgmt | Product + subscription key | Recommended | Unattributed/unmetered consumption |
| 5 | Token exchange | `authentication-managed-identity` | **Required** | Token replay against the backend |
| 6 | Application | Backend checks caller `oid` == APIM identity | **Required** | Any caller that is not APIM |
| 7 | Network | Private Endpoint, public access disabled | **Required** | Every direct network route to the backend |

Layers 6 and 7 are intentionally redundant: one is an application-level control, the other
network-level. Either alone is good; together, misconfiguring one doesn't expose the backend.

## Design decisions

**App Roles instead of scopes.** Scopes (`scp`) require a signed-in user and don't work with
client-credentials or managed-identity callers. APIM's managed identity call to the backend is
app-only, so it can never carry a `scp` claim — app roles (`roles`) are the only primitive that
works for both user and app callers. Combined with **Assignment required = Yes**, an
unassigned caller gets no `roles` claim at all, so every downstream check fails closed.
→ [Add app roles to your application](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps)

**APIM swaps the token instead of forwarding it.** Forwarding the caller's token to the backend
means a leaked token is valid there too (replay), and the backend has to duplicate the gateway's
authorization logic (confused deputy). Swapping to APIM's own managed-identity token means the
caller's credential is only ever valid at the gateway, and the backend only has to answer one
question: "are you APIM?"
→ [authentication-managed-identity policy](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)

**The backend checks the caller's object ID (`oid`).** A valid token with the right role proves
the caller is *some* authorized principal — not specifically APIM. Any other principal granted
`Api.Access` could mint an equally valid token. Pinning `oid` to APIM's managed identity object ID
means the backend accepts exactly one caller in the tenant. This is the application-layer twin of
the Private Endpoint (layer 7): one stops packets, the other stops tokens.

**Two app registrations (API and client), not one.** Separating them means the API registration
holds no credentials (nothing to leak), a compromised client secret affects one client only, and
"who can call this API" is answered by a single list of role assignments on the API's enterprise
application. A registration that both exposes an API and requests tokens for itself is a
configuration smell.

**A subscription key *and* a token — not either/or.** The token is the security control (signed,
short-lived, carries identity/authorization claims). The subscription key is an API-product
management control (quota, rate limit, per-consumer analytics). Never treat the subscription key
as a security boundary — it's a long-lived string with no expiry of its own.

**The Private Endpoint is still needed even though the backend already rejects non-APIM callers.**
Defense in depth: a future code change or misconfiguration could weaken the application check, but
the network layer doesn't depend on application code. It also reduces attack surface (nothing to
scan or fingerprint) and avoids the cost of rejecting requests (TLS handshake, CPU, logging).
→ [App Service Private Endpoints](https://learn.microsoft.com/azure/app-service/networking/private-endpoint)

## Production hardening checklist

| Item | Recommendation | Why |
|------|-----------------|-----|
| Diagnostic logs to Log Analytics (APIM **and** App Service) | Required | Can't investigate a 401/403 after the fact without them |
| Application Insights on APIM | Strongly recommended | End-to-end correlation across the gateway hop |
| Rate limiting and quotas on products | Strongly recommended | Protects the backend from abuse |
| Secrets in Key Vault, not app settings | Required | Centralized rotation and audit |
| Alerts on client secret / certificate expiry | Required | Expired secrets fail with no prior warning |
| Conditional Access on the API | Recommended | MFA / compliant device for interactive callers |
| Periodic access reviews on role assignments | Recommended | Catches stale access |
| Disable or restrict Swagger in production | Recommended | Avoid publishing your schema publicly |
| Microsoft Defender for APIs | Optional | Detects anomalous traffic |
| Least-privilege RBAC (avoid Owner) | Required | Limits blast radius |

Note that **no Azure RBAC role** establishes the APIM-to-backend trust — that's entirely the Entra
ID app role assignment plus the API's own authorization policy. RBAC governs who can *administer*
these resources, not who can *call* the API.

## Choosing SKUs

The cheapest SKU that still satisfies each hard requirement:

| Resource | Cheapest SKU meeting the requirement | Why | Reference |
|----------|----------------------|-----|-----------|
| API Management | **Developer** | Only Developer and Premium support classic VNet injection (required for APIM to reach a Private-Endpoint-only backend) | [APIM feature comparison by tier](https://learn.microsoft.com/azure/api-management/api-management-features) |
| App Service Plan | **B1 (Basic)** | Private Endpoints require Basic or higher; Free/Shared/Consumption aren't supported | [App Service Private Endpoint overview](https://learn.microsoft.com/azure/app-service/networking/private-endpoint) |

## Adapting the pattern

| Situation | Change |
|-----------|--------|
| Multiple permission levels | Define several app roles (`Api.Read`, `Api.Write`); add a policy per role. `required-claims` accepts multiple values. |
| Multiple client apps | One registration per client, each granted the role, each added to `client-application-ids`. |
| Backend needs the original user identity | Have APIM extract claims into signed headers, or use an `on-behalf-of` flow. Don't revert to forwarding the caller's token. |
| Backend is not App Service | Unchanged — Container Apps, AKS, and Functions all support Private Endpoints and token validation. |
| Multi-region | APIM Premium multi-region, one Private Endpoint per region, Front Door for routing. |
| Non-Azure or on-prem backend | Keep layers 1–5; replace the Private Endpoint with ExpressRoute/VPN and the APIM self-hosted gateway. |
| Can't use APIM | Application Gateway + WAF can front the API, but you lose the managed-identity token swap — the backend must then validate caller tokens directly. |

## Reference architecture (Microsoft Learn)

- [Microsoft.Identity.Web documentation](https://learn.microsoft.com/entra/msal/dotnet/microsoft-identity-web/)
- [Entra ID app roles](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps)
- [APIM validate-azure-ad-token policy](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy)
- [APIM authentication-managed-identity policy](https://learn.microsoft.com/azure/api-management/authentication-managed-identity-policy)
- [APIM VNet integration concepts](https://learn.microsoft.com/azure/api-management/virtual-network-concepts)
- [APIM feature comparison by tier](https://learn.microsoft.com/azure/api-management/api-management-features)
- [App Service Private Endpoints](https://learn.microsoft.com/azure/app-service/networking/private-endpoint)
- [Azure Well-Architected Framework — Security](https://learn.microsoft.com/azure/well-architected/security/)
- [Microsoft Zero Trust guidance](https://learn.microsoft.com/security/zero-trust/)
