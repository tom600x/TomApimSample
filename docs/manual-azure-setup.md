# Manual Azure Setup Guide — Zero-Trust API behind API Management

This guide builds the **entire Azure configuration by hand through the Azure Portal**. No CLI, no ARM/Bicep, no
Terraform, no deployment pipelines. It is written for a cloud operations team that requires every change to be made
and reviewed manually.

Target architecture:

```
Internet Client
	↓  OAuth 2.0 token (Microsoft Entra ID)
Microsoft Entra ID
	↓
Azure Front Door + WAF            (optional — see Part 9)
	↓
Azure API Management              validates the caller's token
	↓  re-authenticates with its own managed identity
Private Endpoint                  the only network path into the backend
	↓
ASP.NET Core API on App Service   public access disabled; trusts only APIM's identity
```

---

## Before you begin

### What this guide assumes already exists

| Thing | Sample name used in this guide | Notes |
|-------|-------------------------------|-------|
| Azure subscription | `Contoso-Prod` | You need Owner or Contributor + User Access Administrator |
| Resource group | `rg-contoso-api-prod` | Region: **East US** in all examples |
| App Service (the backend API) | `app-contoso-api-prod` | Already created **and the API code already deployed** |
| App Service Plan | `asp-contoso-api-prod` | See the tier warning below |
| Entra ID app registration — the API | `Contoso.Api` | Already created, no configuration applied yet |
| Entra ID app registration — the client | `Contoso.Client` | Already created, no configuration applied yet |

Replace every sample name with your own values as you go. Everywhere you see a GUID placeholder like
`<contoso-api-client-id>`, substitute the real value you recorded in the previous step.

> ⚠️ **App Service Plan tier.** Private Endpoints and "disable public network access" require **Basic (B1) or
> higher**. They are **not** available on **Free (F1)** or **Shared (D1)** plans. If your plan is Free or Shared,
> scale it up first: **App Service Plan → Scale up (App Service plan) → Basic B1 → Select**. Nothing else in this
> guide depends on the tier.

### What you will create

| Thing | Sample name used in this guide |
|-------|-------------------------------|
| API Management instance | `apim-contoso-prod` |
| Virtual network | `vnet-contoso-prod` |
| APIM subnet | `snet-apim` (10.10.1.0/24) |
| Private Endpoint subnet | `snet-privateendpoints` (10.10.2.0/24) |
| Network security group | `nsg-apim` |
| Private Endpoint | `pe-app-contoso-api-prod` |
| Private DNS zone | `privatelink.azurewebsites.net` |
| App role | `Api.Access` |

### Permissions you need

| Task | Required role |
|------|---------------|
| Configure app registrations, app roles, grant admin consent | **Application Administrator** or **Cloud Application Administrator** (Entra ID directory role) |
| Assign app roles to users and service principals | **Application Administrator** *or* be an owner of the enterprise application |
| Create APIM, VNet, Private Endpoint, Private DNS | **Contributor** on the resource group |
| Grant admin consent tenant-wide | **Privileged Role Administrator** or **Global Administrator** |

### Record your values as you go

Keep this table open and fill it in. Later parts depend on almost all of it.

| Value | Where you get it | Your value |
|-------|------------------|-----------|
| Tenant ID | Entra ID → Overview | |
| `Contoso.Api` Application (client) ID | App registration → Overview | |
| `Contoso.Api` Application ID URI | Part 1, Step 2 | |
| `Contoso.Api` **enterprise application** Object ID | Part 1, Step 5 | |
| `Api.Access` app role ID | Part 1, Step 3 | |
| `Contoso.Client` Application (client) ID | App registration → Overview | |
| `Contoso.Client` **enterprise application** Object ID | Part 3, Step 2 | |
| `Contoso.Client` client secret | Part 2, Step 3 | |
| APIM managed identity Object ID | Part 4, Step 2 | |
| APIM subscription key | Part 5, Step 4 | |

> ⚠️ **Application ID vs. Object ID.** These are different GUIDs and mixing them up is the single most common
> mistake in this process. An *app registration* has an **Application (client) ID**. Its matching *enterprise
> application* (service principal) has an **Object ID**. App **role assignments** always use **Object IDs**. Token
> configuration and policies use **Application IDs**.

---

## Part 1 — Configure the API app registration (`Contoso.Api`)

`Contoso.Api` is a **pure resource**. It represents the protected API. It never signs anyone in, never requests a
token, and has no redirect URIs and no client secret.

### Step 1.1 — Record the Application ID

1. Go to **Microsoft Entra ID → App registrations → Contoso.Api**.
2. On the **Overview** blade, copy **Application (client) ID** and **Directory (tenant) ID** into your value table.

### Step 1.2 — Set the Application ID URI

1. Select **Expose an API** in the left menu.
2. Next to **Application ID URI**, select **Add**.
3. Accept the default `api://<contoso-api-client-id>`.
4. Select **Save**.

> Do **not** add any scopes under "Expose an API". This design uses **App Roles**, not delegated scopes. Scopes
> only describe what a signed-in user permits an app to do on their behalf; app roles are assignable to
> applications and managed identities as well, which is what the APIM-to-backend hop requires.

### Step 1.3 — Create the `Api.Access` app role

1. Select **App roles** in the left menu.
2. Select **Create app role** and fill in:

   | Field | Value |
   |-------|-------|
   | Display name | `Api.Access` |
   | Allowed member types | **Both (Users/Groups + Applications)** |
   | Value | `Api.Access` |
   | Description | `Allows the caller to invoke the Contoso API.` |
   | Do you want to enable this app role? | ✅ Checked |

3. Select **Apply**.
4. Reopen the role and copy its **ID** (a GUID) into your value table.

> ⚠️ **"Allowed member types" must be *Both*.** *Users/Groups* alone serves interactive callers (Swagger UI, a
> user signing in). *Applications* alone serves daemons, service principals, and managed identities. This
> architecture needs both: a human developer testing through Swagger **and** APIM's managed identity calling the
> backend. Choosing only one silently blocks the other half of the flow.

### Step 1.4 — Require v2 access tokens

1. Select **Manifest** in the left menu.
2. Find `"requestedAccessTokenVersion"` and set it to `2`:
   ```json
   "api": {
	   "requestedAccessTokenVersion": 2
   }
   ```
3. Select **Save**.

> ⚠️ **This changes the `aud` claim.** With v1 tokens `aud` is the Application ID URI (`api://<guid>`); with v2
> tokens `aud` is the **bare Application ID GUID**. Your APIM policy and your API must accept **both** forms, or
> every call fails with `401`. Part 5 and Part 7 handle this.

### Step 1.5 — Require explicit assignment

This is what turns the app role from documentation into enforcement. Without it, any principal in the tenant can
get a token for your API.

1. Go to **Microsoft Entra ID → Enterprise applications**.
2. Change the **Application type** filter to **All applications** and search for `Contoso.Api`.
3. Open it and copy the **Object ID** into your value table — you will need it for every app role assignment.
4. Select **Properties**.
5. Set **Assignment required?** to **Yes**.
6. Select **Save**.

### Step 1.6 — Remove any self-referencing permission

Some project templates add the API as a permission on itself.

1. Back on the **app registration** → **API permissions**.
2. If `Contoso.Api` appears in its own permissions list, select the **…** menu next to it and **Remove permission**.

A resource API should not request permissions.

---

## Part 2 — Configure the client app registration (`Contoso.Client`)

`Contoso.Client` is a **pure client**. It requests tokens for `Contoso.Api`. It must **not** expose an API or own
any scopes.

### Step 2.1 — Remove anything that makes it look like a resource

1. Go to **App registrations → Contoso.Client → Expose an API**.
2. If an **Application ID URI** is set, select the **…** menu and **Delete** it.
3. Delete any scopes listed under **Scopes defined by this API**.

> If a previously published scope is in use, deleting it will break those callers. Disable the scope first, confirm
> nothing is calling it, then delete.

### Step 2.2 — Add redirect URIs (only if you use an interactive UI such as Swagger)

1. Select **Authentication → Add a platform**.
2. Choose **Single-page application** and enter your Swagger redirect URI, for example
   `https://app-contoso-api-prod.azurewebsites.net/swagger/oauth2-redirect.html`.
3. Add `https://localhost:5001/swagger/oauth2-redirect.html` as well if developers test locally.
4. Select **Configure**.

> Use the **Single-page application** platform, not **Web**. SPA registrations enforce **Authorization Code +
> PKCE**, which is the Microsoft-recommended flow for browser-based clients. Never enable the **implicit grant**
> checkboxes.

### Step 2.3 — Create a client secret (only for daemon / service-to-service callers)

1. Select **Certificates & secrets → Client secrets → New client secret**.
2. Enter a description and choose the **shortest** expiry that fits your rotation process.
3. Select **Add** and copy the **Value** immediately — it is never shown again.

> 🔐 **Production guidance: prefer certificates or Workload Identity Federation over secrets.** If you must use a
> secret, store it in **Azure Key Vault** and reference it from App Service settings — never in `appsettings.json`
> or source control. Put a calendar reminder on the expiry date; an expired secret produces a confusing
> authentication failure with no warning beforehand.

### Step 2.4 — Add the delegated permission (only for interactive UI callers)

1. Select **API permissions → Add a permission → My APIs → Contoso.Api**.
2. Choose **Delegated permissions**, tick **Api.Access**, and select **Add permissions**.
3. Select **Grant admin consent for \<your tenant\>** and confirm.
4. Verify the **Status** column shows a green **Granted for \<tenant\>**.

> This delegated permission covers *users signing in through the client*. It does **not** cover the client calling
> on its own behalf — that requires Part 3, Step 2.

---

## Part 3 — Assign the `Api.Access` role

The role must be assigned to every principal that will call the API. In this architecture there are up to three.

### Step 3.1 — Assign the role to users (interactive callers)

1. Go to **Entra ID → Enterprise applications → Contoso.Api → Users and groups**.
2. Select **Add user/group**.
3. Under **Users**, pick the developers or (better) a security group such as `sg-contoso-api-users`.
4. Under **Select a role**, pick **Api.Access**.
5. Select **Assign**.

> Assign to **groups**, not individual users, wherever your licensing allows it. Group-based assignment is the
> auditable, scalable pattern.

### Step 3.2 — Assign the role to the client's service principal (daemon callers)

Needed only if `Contoso.Client` calls the API **on its own behalf** using the client-credentials flow.

> ⚠️ **This cannot be done in the Azure Portal.** The "Users and groups" blade only accepts users and groups, not
> service principals. You must use **Microsoft Graph Explorer**, which is still a manual, browser-based operation.

1. First get the client's service principal Object ID: **Entra ID → Enterprise applications → All applications →
   Contoso.Client → Overview → Object ID**. Record it.
2. Open **<https://developer.microsoft.com/graph/graph-explorer>** and sign in with an account holding
   **Application Administrator**.
3. Select **Modify permissions** and consent to `AppRoleAssignment.ReadWrite.All` and `Application.Read.All`.
4. Set the method to **POST** and the URL to:
   ```
   https://graph.microsoft.com/v1.0/servicePrincipals/<contoso-api-enterprise-app-object-id>/appRoleAssignedTo
   ```
5. On the **Request body** tab, enter:
   ```json
   {
	 "principalId": "<contoso-client-enterprise-app-object-id>",
	 "resourceId":  "<contoso-api-enterprise-app-object-id>",
	 "appRoleId":   "<api-access-app-role-id>"
   }
   ```
6. Select **Run query**. A `201 Created` response means success.

> **Why a delegated permission is not enough.** The client-credentials flow always requests the `/.default` scope.
> Entra ID populates the `roles` claim in an app-only token purely from **application** app role assignments on the
> calling service principal. Delegated permissions are ignored entirely. Skipping this step produces a token with
> **no `roles` claim**, and the call is rejected.

You can verify the assignment afterwards in the portal: **Enterprise applications → Contoso.Api → Users and
groups** now lists the application.

### Step 3.3 — Assign the role to APIM's managed identity

Do this **after** Part 4, Step 2 (once the identity exists). It uses the exact same Graph Explorer procedure as
Step 3.2, with `principalId` set to the **APIM managed identity Object ID**:

```json
{
  "principalId": "<apim-managed-identity-object-id>",
  "resourceId":  "<contoso-api-enterprise-app-object-id>",
  "appRoleId":   "<api-access-app-role-id>"
}
```

---

## Part 4 — Create and configure API Management

### Step 4.1 — Create the APIM instance

1. In the portal, select **Create a resource** and search for **API Management**.
2. Select **Create** and fill in the **Basics** tab:

   | Field | Value |
   |-------|-------|
   | Subscription | `Contoso-Prod` |
   | Resource group | `rg-contoso-api-prod` |
   | Region | **East US** (must match the VNet you create in Part 6) |
   | Resource name | `apim-contoso-prod` |
   | Organization name | `Contoso` |
   | Administrator email | your ops distribution list |
   | Pricing tier | **Developer** for non-production, **Premium** for production |

3. Select **Review + create**, then **Create**.

> ⏱️ **Provisioning takes 30–45 minutes** for Developer and Premium tiers. Start it now and continue reading.

> ⚠️ **Choose the tier carefully — you cannot change tier *type* later.** Moving between the Consumption tier and
> the dedicated tiers (Developer/Basic/Standard/Premium) is **not supported**. The portal rejects it with
> `ChangingSkuTypeNotSupported`. The only route is to delete the instance, **purge** the soft-deleted record
> (**API Management services → Deleted services → Purge**) to free the name, and create it again from scratch —
> losing every API, product, policy, subscription key, **and the managed identity**. Scaling *units* within the
> dedicated tiers is fine.
>
> ⚠️ **Consumption and the Basic/Standard v1 tiers do not support VNet integration**, so they cannot reach a
> Private Endpoint. If you intend to complete Part 6, you must choose **Developer** or **Premium**.

### Step 4.2 — Enable the system-assigned managed identity

1. Open `apim-contoso-prod` → **Managed identities** (under *Security*).
2. On the **System assigned** tab, set **Status** to **On**.
3. Select **Save** and confirm.
4. Copy the **Object (principal) ID** that appears into your value table.

> ⚠️ **This Object ID is destroyed if you ever delete and recreate the APIM instance**, and the replacement gets a
> brand-new one. Every app role assignment and every backend trust configuration referencing the old ID must be
> redone.

Now go back and complete **Part 3, Step 3.3** to grant this identity the `Api.Access` role.

### Step 4.3 — Register the backend App Service

1. Open `apim-contoso-prod` → **APIs → Backends** (under *APIs*).
2. Select **+ Add** and fill in:

   | Field | Value |
   |-------|-------|
   | Name | `backend-contoso-api` |
   | Type | **Custom URL** |
   | Runtime URL | `https://app-contoso-api-prod.azurewebsites.net` |
   | Validate certificate chain / name | ✅ Both checked |

3. Select **Create**.

---

## Part 5 — Publish the API through APIM

### Step 5.1 — Create the API

1. Open `apim-contoso-prod` → **APIs → + Add API**.
2. Choose **HTTP** (or **OpenAPI** if you have a spec — recommended, it creates all operations for you).
3. Fill in:

   | Field | Value |
   |-------|-------|
   | Display name | `Contoso API` |
   | Name | `contoso-api` |
   | Web service URL | `https://app-contoso-api-prod.azurewebsites.net` |
   | API URL suffix | `contoso` |
   | Products | leave blank for now — Step 5.3 handles it |

4. Select **Create**.

Your gateway URL is now `https://apim-contoso-prod.azure-api.net/contoso`.

### Step 5.2 — Add operations

If you imported an OpenAPI document, skip this step.

1. Select the API → **+ Add operation**.
2. For example:

   | Field | Value |
   |-------|-------|
   | Display name | `Get weather forecast` |
   | Name | `get-weatherforecast` |
   | URL | **GET** `/WeatherForecast` |

3. Select **Save**. Repeat for each endpoint.

### Step 5.3 — Add the API to a product (this is what requires a subscription key)

1. Select the API → **Settings** tab.
2. Under **Products**, add the API to a product such as the built-in **Unlimited**, or create your own under
   **APIs → Products** with sensible rate limits and quotas.
3. Select **Save**.

> With **Subscription required** enabled on the product (the default), every call must include an
> `Ocp-Apim-Subscription-Key` header. This is an API-consumer management control — it identifies and rate-limits
> the calling *application*. It is **not** a security boundary and is **not** a substitute for the OAuth token. Use
> both.

### Step 5.4 — Get the subscription key

1. Open `apim-contoso-prod` → **Subscriptions**.
2. Find the subscription for your product, select the **…** menu, and choose **Show/hide keys**.
3. Copy the **Primary key** into your value table.

### Step 5.5 — Apply the inbound policy

This policy is the heart of the pattern. It does two things: it **validates the caller's token**, then it
**discards the caller's identity and re-authenticates to the backend as APIM itself**.

1. Select the API → **Design** tab → select **All operations**.
2. In the **Inbound processing** box, select the **`</>`** (code editor) icon.
3. Replace the contents with the following, substituting your values:

```xml
<policies>
  <inbound>
	<base />

	<!-- 1. Validate the caller's Entra ID token: signature, issuer, tenant, expiry,
			audience, allowed client application, and the required app role. -->
	<validate-azure-ad-token
		tenant-id="<your-tenant-id>"
		header-name="Authorization"
		failed-validation-httpcode="401"
		failed-validation-error-message="Unauthorized: invalid or missing Entra ID token.">
	  <client-application-ids>
		<application-id><contoso-client-application-id></application-id>
	  </client-application-ids>
	  <audiences>
		<!-- v1 tokens carry the Application ID URI; v2 tokens carry the bare GUID. Accept both. -->
		<audience>api://<contoso-api-application-id></audience>
		<audience><contoso-api-application-id></audience>
	  </audiences>
	  <required-claims>
		<claim name="roles" match="any">
		  <value>Api.Access</value>
		</claim>
	  </required-claims>
	</validate-azure-ad-token>

	<!-- 2. Acquire a fresh token as APIM's own managed identity and overwrite the
			Authorization header. The caller's token never reaches the backend. -->
	<authentication-managed-identity
		resource="api://<contoso-api-application-id>"
		output-token-variable-name="apim-backend-token"
		ignore-error="false" />
	<set-header name="Authorization" exists-action="override">
	  <value>@("Bearer " + (string)context.Variables["apim-backend-token"])</value>
	</set-header>
  </inbound>
  <backend>
	<base />
  </backend>
  <outbound>
	<base />
	<!-- Never leak backend implementation details to the internet. -->
	<set-header name="X-Powered-By" exists-action="delete" />
	<set-header name="X-AspNet-Version" exists-action="delete" />
	<set-header name="Server" exists-action="delete" />
  </outbound>
  <on-error>
	<base />
  </on-error>
</policies>
```

4. Select **Save**.

> ⚠️ **`ignore-error="false"` matters.** If it were `true` and the managed identity token acquisition failed, APIM
> would forward the request to the backend with **no** `Authorization` header, converting a clean failure into a
> confusing one.

> ⚠️ **Policy scope.** `validate-azure-ad-token` is valid at the API and operation scope. Placing it in the
> **global** (All APIs) scope produces `Policy scope is not allowed in this section`.

---

## Part 6 — Network isolation

Everything so far is **identity**-layer security. This part adds the **network** layer so the backend is not merely
protected from unauthorized callers — it is unreachable by them.

> ⚠️ **Order matters.** Build the network path *first* and verify it, and only then disable public access. Doing it
> in the opposite order will take your API offline.

### Step 6.1 — Create the virtual network

1. **Create a resource → Virtual network → Create**.

   | Field | Value |
   |-------|-------|
   | Resource group | `rg-contoso-api-prod` |
   | Name | `vnet-contoso-prod` |
   | Region | **East US** — must match the APIM region exactly |

2. On the **IP addresses** tab, set the address space to `10.10.0.0/16`.
3. Add a subnet named **`snet-apim`** with range `10.10.1.0/24`.
4. Add a subnet named **`snet-privateendpoints`** with range `10.10.2.0/24`.
5. Select **Review + create → Create**.

> The APIM subnet must be **empty, dedicated to APIM, and in the same region and subscription** as the APIM
> instance. Do not place anything else in it.

### Step 6.2 — Create the network security group for the APIM subnet

APIM's control plane requires specific inbound access. Without it, the instance is reported unhealthy and stops
receiving configuration updates.

1. **Create a resource → Network security group → Create**, named `nsg-apim` in **East US**.
2. Open it → **Inbound security rules → + Add** and create these three rules:

   | Priority | Name | Source | Source port | Destination | Dest. port | Protocol | Action | Why |
   |---------:|------|--------|------------|-------------|-----------|----------|--------|-----|
   | 100 | `AllowApimManagement` | **Service Tag** → `ApiManagement` | `*` | **Service Tag** → `VirtualNetwork` | `3443` | TCP | Allow | APIM control plane — **mandatory** |
   | 110 | `AllowGatewayHttps` | **Service Tag** → `Internet` | `*` | **Service Tag** → `VirtualNetwork` | `443` | TCP | Allow | Client traffic (External mode only) |
   | 120 | `AllowLbHealthProbe` | **Service Tag** → `AzureLoadBalancer` | `*` | **Service Tag** → `VirtualNetwork` | `6390` | TCP | Allow | Azure Load Balancer health probe |

3. Leave the default outbound rules in place. APIM needs outbound access to **Storage**, **SQL**, **Key Vault**,
   and **Azure Monitor**; the default `AllowInternetOutBound` rule covers this. If your organization replaces that
   rule with a deny, you must add explicit service-tag allow rules for `Storage`, `Sql`, `AzureKeyVault`, and
   `AzureMonitor`, or APIM will break.
4. Go to **vnet-contoso-prod → Subnets → snet-apim**, set **Network security group** to `nsg-apim`, and **Save**.

### Step 6.3 — Join APIM to the virtual network

1. Open `apim-contoso-prod` → **Network** (under *Deployment + infrastructure*).
2. Select **Virtual network**.
3. Choose **External**.
4. Select `vnet-contoso-prod` and the `snet-apim` subnet.
5. Select **Apply**.

> **External vs. Internal:**
> - **External** — the gateway keeps a public IP and stays reachable from the internet, but APIM gains a network
>   presence inside the VNet so it can reach private resources. **This is what you want** when APIM is your public
>   front door.
> - **Internal** — the gateway is reachable only from inside the VNet. Choose this only when something else (Azure
>   Front Door with Private Link, Application Gateway) fronts APIM and you need the gateway itself to be private.
>
> ⏱️ This change takes **30–45 minutes**. The gateway continues serving traffic while it applies.

### Step 6.4 — Create the Private Endpoint for the App Service

1. Open `app-contoso-api-prod` → **Networking** → **Private endpoints** → **+ Add** → **Express** (or use
   **Create a resource → Private endpoint**).

   | Field | Value |
   |-------|-------|
   | Name | `pe-app-contoso-api-prod` |
   | Region | **East US** |
   | Resource type | `Microsoft.Web/sites` |
   | Resource | `app-contoso-api-prod` |
   | Target sub-resource | `sites` |
   | Virtual network | `vnet-contoso-prod` |
   | Subnet | `snet-privateendpoints` |
   | Integrate with private DNS zone | **Yes** |
   | Private DNS zone | `privatelink.azurewebsites.net` (let the portal create it) |

2. Select **Review + create → Create**.
3. Once created, open it and note the **private IP address** (for example `10.10.2.4`).

Letting the portal handle DNS automatically creates the `privatelink.azurewebsites.net` private DNS zone, links it
to `vnet-contoso-prod`, and adds A records for both `app-contoso-api-prod.azurewebsites.net` and its `.scm.`
counterpart.

> ⚠️ **If you create the zone manually, you must link it to the VNet.** A private DNS zone that is not linked to
> the virtual network resolves nothing. Verify under **privatelink.azurewebsites.net → Virtual network links**.
> Missing this link is the most common cause of a Private Endpoint that "exists but doesn't work" — APIM keeps
> resolving the public IP and the call fails as soon as you complete Step 6.6.

### Step 6.5 — Verify the private path works *before* locking the door

1. Open `apim-contoso-prod` → **APIs → Contoso API →** select an operation → the **Test** tab.
2. Send a request and confirm you get a successful response.

At this point traffic may still be flowing over the public path. The real verification is in Step 6.7.

### Step 6.6 — Disable public network access on the App Service

1. Open `app-contoso-api-prod` → **Networking**.
2. Under **Inbound traffic configuration**, select **Public network access**.
3. Set it to **Disabled**.
4. Select **Save**.

> ⚠️ **This also cuts off your own management access.** The Kudu/SCM site, "Advanced Tools", log streaming, and
> portal-based deployment all go through the same public endpoint. After this change, deployments must run from an
> agent inside the VNet, through a self-hosted build agent, or via a jump box. Plan your deployment path before
> you flip this switch.
>
> You can allow a controlled exception under **Networking → Access restrictions** — for example, permitting your
> corporate egress IP range to reach the SCM site only.

### Step 6.7 — Verify the isolation

| Test | How | Expected |
|------|-----|----------|
| Public path is closed | From your laptop, browse to `https://app-contoso-api-prod.azurewebsites.net/WeatherForecast` | **403 Forbidden** with an Azure networking error page — the request never reaches your code |
| Private path still works | APIM **Test** tab, or a real client call through the gateway | **200 OK** |

If the second test now fails with a timeout or `500`, the private DNS link from Step 6.4 is almost certainly
missing or the APIM VNet integration has not finished applying.

---

## Part 7 — Configure the backend App Service

The API code must be told which managed identity to trust. These are plain application settings — no redeployment
is required to change them.

1. Open `app-contoso-api-prod` → **Environment variables** (formerly *Configuration*) → **App settings**.
2. Add the following:

   | Name | Value |
   |------|-------|
   | `AzureAd__TenantId` | `<your-tenant-id>` |
   | `AzureAd__ClientId` | `<contoso-api-application-id>` |
   | `AzureAd__Audience` | `api://<contoso-api-application-id>` |
   | `ApiSecurity__RequiredAppRole` | `Api.Access` |
   | `ApiSecurity__AllowedManagedIdentityObjectId` | `<apim-managed-identity-object-id>` |
   | `ApiSecurity__EnforceManagedIdentityTrust` | `true` |

3. Select **Apply** and confirm the restart.

> The double underscore `__` maps to configuration nesting, so `ApiSecurity__EnforceManagedIdentityTrust`
> overrides `ApiSecurity:EnforceManagedIdentityTrust` in `appsettings.json`. This makes the APIM identity
> swappable without a code change — valuable given that recreating APIM produces a new Object ID.

4. Confirm **HTTPS Only** is **On** under **Configuration → General settings**, and that **Minimum TLS version**
   is **1.2** or higher.

---

## Part 8 — Post-setup hardening checklist

| Item | Where | Why |
|------|-------|-----|
| Diagnostic logs → Log Analytics | APIM → **Diagnostic settings**; App Service → **Diagnostic settings** | Without them you cannot investigate a `401`/`403` after the fact |
| Application Insights on APIM | APIM → **Application Insights** | End-to-end request correlation across the gateway hop |
| Rate limiting and quotas | APIM → **Products → Policies** | Protects the backend from abuse and runaway clients |
| Microsoft Defender for APIs | Defender for Cloud | Detects anomalous API traffic |
| Client secret expiry alerts | Entra ID → app registration | An expired secret fails with no prior warning |
| Conditional Access on the API | Entra ID → **Conditional Access** | Enforce MFA / compliant device for interactive callers |
| Restrict APIM's own management access | APIM → **Access control (IAM)** | Use built-in roles; avoid Owner |
| Review app role assignments quarterly | Entra ID → **Identity Governance → Access reviews** | Catches stale access |

### Azure RBAC roles for ongoing operation

| Role | Scope | Assign to | Purpose |
|------|-------|-----------|---------|
| **API Management Service Contributor** | `apim-contoso-prod` | API platform team | Manage APIs, products, policies |
| **API Management Service Reader** | `apim-contoso-prod` | Support / on-call | Read-only troubleshooting |
| **Website Contributor** | `app-contoso-api-prod` | App team | Manage the App Service |
| **Network Contributor** | `vnet-contoso-prod` | Network team | Manage subnets and the Private Endpoint |
| **Private DNS Zone Contributor** | `privatelink.azurewebsites.net` | Network team | Manage DNS records |

> No Azure RBAC role establishes the APIM-to-backend trust. That relationship is **entirely** an Entra ID app role
> assignment (Part 3, Step 3.3) plus the API's own authorization policy. RBAC governs who can *administer* these
> resources, not who can *call* the API.

---

## Part 9 — Optional: Azure Front Door with WAF

Place Front Door in front of APIM for global routing, DDoS protection, and OWASP rule enforcement.

1. **Create a resource → Front Door and CDN profiles → Azure Front Door → Custom create**.
2. Add an **origin group** with `apim-contoso-prod.azure-api.net` as the origin (origin type **Custom**).
3. Attach a **WAF policy** in **Prevention** mode using the **Microsoft Default Rule Set**.
4. Lock APIM down so it accepts traffic **only** from your Front Door instance. Add this to the APIM **global**
   inbound policy, substituting your Front Door ID from **Front Door → Overview → Front Door ID**:

   ```xml
   <check-header name="X-Azure-FDID" failed-check-httpcode="403"
				 failed-check-error-message="Forbidden: requests must arrive via Front Door."
				 ignore-case="true">
	 <value><your-front-door-id></value>
   </check-header>
   ```

> Without step 4, an attacker can bypass the WAF entirely by calling the APIM gateway hostname directly. Front
> Door in front of an unrestricted origin provides no security benefit.

---

## Troubleshooting

| Symptom | Most likely cause | Fix |
|---------|-------------------|-----|
| `401` at APIM, message from your policy | Token `aud` doesn't match the policy | You set `requestedAccessTokenVersion: 2` (Part 1.4) but listed only `api://<guid>`. Add the bare GUID as a second `<audience>`. |
| `401` at APIM, `AADSTS500011` when getting the token | Client requested the wrong resource | The scope must be `api://<contoso-**api**-application-id>/.default` — the **API's** ID, not the client's. |
| `401` at APIM and the token has **no** `roles` claim | Missing application app role assignment | Complete Part 3, Step 3.2 via Graph Explorer. A delegated permission does not populate `roles`. |
| `403` from the **backend** with a valid token | Token is valid but authorization failed | Either the `oid` doesn't match `ApiSecurity__AllowedManagedIdentityObjectId`, or the `roles` claim isn't being read. In ASP.NET Core, set `options.MapInboundClaims = false` — otherwise JwtBearer renames `roles` to a legacy WS-Federation URI and every role check silently fails. |
| `403` calling the App Service hostname directly | ✅ Working as designed | This is the zero-trust behaviour you configured. |
| `500` / timeout through APIM after Step 6.6 | Private DNS zone not linked to the VNet | Check **privatelink.azurewebsites.net → Virtual network links**. |
| APIM shows "unhealthy" after joining the VNet | NSG blocks port 3443 | Add the `AllowApimManagement` inbound rule (Part 6.2). |
| `Policy scope is not allowed in this section` | Policy placed at the wrong scope | `validate-azure-ad-token` belongs at API or operation scope, not global. |
| Token acquisition fails suddenly, no config changed | Client secret expired | Create a new secret (Part 2.3) and update the consumer. |
| Cannot deploy to the App Service any more | Public access disabled (Step 6.6) | Deploy from inside the VNet, or add an SCM access restriction for your build agent's IP. |

### How to read the status codes

This distinction will save you hours:

- **`401 Unauthorized`** — the token itself was rejected. Look at signature, issuer, tenant, audience, expiry.
- **`403 Forbidden`** — the token was **valid**, but the caller isn't permitted. Look at the `roles` claim, the
  `oid` claim, and your authorization policy.

### Inspecting a token

Paste the token into **<https://jwt.ms>** (a Microsoft-operated decoder) and check:

| Claim | Should be |
|-------|-----------|
| `aud` | `<contoso-api-application-id>` (v2) or `api://<contoso-api-application-id>` (v1) |
| `iss` | `https://login.microsoftonline.com/<tenant-id>/v2.0` or `https://sts.windows.net/<tenant-id>/` |
| `tid` | your tenant ID |
| `roles` | contains `Api.Access` |
| `oid` | for the APIM hop, the APIM managed identity Object ID |

> 🔐 Only ever paste **non-production** tokens into any decoder, and treat a token as a live credential until it
> expires.

### Enabling APIM request tracing

1. APIM → **APIs →** your API → **Test** tab.
2. Send a request, then open the **Trace** tab in the response.

The trace shows exactly which policy rejected the request and why — far faster than guessing from the status code.

---

## Summary of what you built

| Layer | Control | What it stops |
|-------|---------|---------------|
| Identity | Entra ID token validation at APIM (issuer, tenant, audience, signature, expiry) | Forged, expired, and foreign-tenant tokens |
| Authorization | `Api.Access` app role + **Assignment required** | Valid tokens from principals you never authorized |
| Consumer management | APIM product + subscription key | Unmetered and unattributable API consumption |
| Identity (hop 2) | APIM managed identity token; caller's token discarded | Token replay against the backend; confused-deputy attacks |
| Application | Backend validates the `oid` matches APIM's identity | Any caller that is not APIM, even with a valid token |
| Network | Private Endpoint + public access disabled | Every direct network path to the backend |
| Edge (optional) | Front Door WAF + `X-Azure-FDID` check | OWASP-class attacks and WAF bypass |

Each layer stands alone. If the app role assignment were mistakenly granted too widely, the network layer still
blocks direct access. If someone re-enabled public access, the application layer still rejects non-APIM callers.
That redundancy is the point.
