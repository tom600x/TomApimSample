# Infrastructure as Code — Zero-Trust APIM Architecture

Bicep templates and PowerShell scripts that provision the entire
`Internet Client → Entra ID → API Management → Private Endpoint → App Service` architecture
described in the [root README](../README.md).

## What this deploys

| Resource | Purpose |
|---|---|
| Virtual Network + 2 subnets | Isolated network for APIM and the Private Endpoint |
| Network Security Group | Required inbound rules for APIM VNet integration (ports 3443, 443, 6390) |
| App Service Plan (B1+) + Web App | Backend API host, public network access disabled |
| Private Endpoint + Private DNS zone | Makes the Web App reachable only from inside the VNet |
| API Management (Developer/Premium, External VNet mode, system-assigned identity) | Gateway that validates caller tokens and re-authenticates to the backend |
| APIM API + inbound policy | Publishes the backend through APIM with `validate-azure-ad-token` + `authentication-managed-identity` |

**Not included** (not ARM/Bicep resources — see [`entra-setup.ps1`](./entra-setup.ps1)):
Entra ID app registrations, the `Api.Access` app role, and app-role assignments.

## Prerequisites

- Azure CLI (`az`), logged in with a role that can create resources and role assignments
  (Contributor + User Access Administrator, or Owner) on the target subscription.
- Microsoft Graph permissions to create app registrations and app-role assignments
  (Application Administrator or Global Administrator, or equivalent delegated Graph scopes).
- PowerShell 7+.
- Bicep CLI (bundled with recent `az` — run `az bicep install` if needed).

## Usage

### 1. Create the Entra ID app registrations

```powershell
cd infra
./entra-setup.ps1
```

This creates (or reuses, if they already exist by display name):

- The backend API app registration, its `api://<client-id>` identifier URI, and the `Api.Access`
  app role (`allowedMemberTypes: User, Application` — required so both delegated *and*
  application/managed-identity tokens can carry the role).
- The client (Swagger/UI) app registration and, optionally, a new client secret.
- The `Api.Access` app-role assignment from the client app to the API app (needed for
  client-credentials / service-to-service calls).

Note the `ApiAppClientId` and `SwaggerClientId` printed at the end — you'll need them for step 2.

### 2. Deploy the Azure infrastructure

```powershell
./deploy.ps1
```

You'll be prompted for every resource name and setting, each with a default shown in
`[brackets]` — press Enter to accept it. The script:

1. Confirms your Azure subscription/tenant (or runs `az login`).
2. Creates the resource group if it doesn't exist.
3. Runs `az deployment group what-if` so you can review changes before they're applied.
4. Deploys `main.bicep` on confirmation.
5. Prints the APIM gateway URL, API call URL, and **APIM's managed identity object ID**.

### 3. Grant APIM's managed identity the app role

APIM's managed identity doesn't exist until after step 2, so run `entra-setup.ps1` again and
paste the `apimManagedIdentityPrincipalId` value from the deploy output when prompted:

```powershell
./entra-setup.ps1
# ... when asked for the APIM managed identity object ID, paste the value from deploy.ps1's output
```

Alternatively, assign only the existing app role without running the broader Entra setup:

```powershell
./assign-app-role.ps1 `
  -PrincipalId <apim-managed-identity-object-id> `
  -ResourceId <api-enterprise-application-object-id> `
  -AppRoleId <api-access-app-role-id> `
  -TenantId <tenant-id>
```

The script validates that the role exists, is enabled, and permits `Application` principals. It
is idempotent and supports `-WhatIf`. App-role assignment changes can take several hours to appear
in managed-identity tokens because those tokens are cached.

### 4. Deploy application code

`main.bicep` provisions the App Service but does not deploy code to it. Publish
`ApimSample.Api` with your usual method, e.g.:

```powershell
dotnet publish ..\ApimSample.Api\ApimSample.Api.csproj -c Release -o .\publish
Compress-Archive -Path .\publish\* -DestinationPath .\publish.zip -Force
az webapp deploy --resource-group <rg> --name <webAppName> --src-path .\publish.zip --type zip
```

## File structure

```
infra/
  main.bicep                        Orchestrates every module below
  main.parameters.json              Non-interactive parameter defaults (edit the two REPLACE-WITH values)
  deploy.ps1                        Interactive deployment wrapper (prompts + defaults)
  entra-setup.ps1                   Entra ID app registrations, app role, and role assignments
  policy/
	api-policy.template.xml         APIM inbound policy template (tokens substituted by main.bicep)
  modules/
	network.bicep                   VNet, subnets, NSG
	appService.bicep                App Service Plan + Web App (public access disabled)
	privateEndpoint.bicep           Private Endpoint + private DNS zone + VNet link
	apim.bicep                      APIM instance, External VNet mode, system-assigned identity
	apimApi.bicep                   APIM API + policy + product association
```

## Re-running / updating

Both scripts and `main.bicep` are idempotent — re-running `deploy.ps1` against the same resource
group updates existing resources in place, and `entra-setup.ps1` detects existing app
registrations/roles/assignments by name and skips creating duplicates.

## Manual (portal-only) alternative

If your organization requires every step to be performed by hand through the Azure Portal
(no CLI/IaC), follow [`../docs/manual-azure-setup.md`](../docs/manual-azure-setup.md) instead.

## SKUs, API versions, and Entra ID resources

For the reasoning behind the SKU choices (Developer APIM, B1 App Service Plan) and why Entra ID
app registrations/roles/assignments can't be expressed in Bicep, see
[`../docs/security-architecture.md`](../docs/security-architecture.md#choosing-skus).
