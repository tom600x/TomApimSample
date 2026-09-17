#Requires -Version 7.0
<#
.SYNOPSIS
	Creates/updates the Entra ID app registrations, the Api.Access app role, and the app-role
	assignments required by the zero-trust APIM architecture.

.DESCRIPTION
	Bicep/ARM cannot create Entra ID app registrations, app roles, or app-role assignments — those
	are Microsoft Graph objects, not Azure Resource Manager resources. This script is the companion
	to main.bicep/deploy.ps1 and handles that part using the Azure CLI's Graph wrappers (az ad) and
	direct Graph REST calls (az rest) for the parts az ad does not expose (application-type app-role
	assignments).

	Run this BEFORE deploy.ps1 to obtain apiAppClientId/swaggerClientAppId for the Bicep deployment,
	and run it AGAIN AFTER deploy.ps1 to grant APIM's managed identity the Api.Access app role
	(APIM's principal ID is only known after the APIM resource is created).

	Idempotent: safe to re-run. Existing app registrations, roles, and assignments are detected and
	left alone; only missing pieces are created.

.EXAMPLE
	./entra-setup.ps1
#>

[CmdletBinding()]
param()

function Read-WithDefault {
	param(
		[Parameter(Mandatory)][string]$Prompt,
		[string]$Default = ''
	)
	$suffix = if ($Default) { " [$Default]" } else { '' }
	$value = Read-Host "$Prompt$suffix"
	if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
	return $value
}

Write-Host '=== Entra ID Setup for Zero-Trust APIM Architecture ===' -ForegroundColor Cyan
Write-Host 'Press Enter on any prompt to accept the default shown in [brackets].' -ForegroundColor DarkGray
Write-Host ''

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
	Write-Host 'Not logged in. Launching az login...' -ForegroundColor Yellow
	az login | Out-Null
	$account = az account show | ConvertFrom-Json
}
Write-Host "Tenant: $($account.tenantId)" -ForegroundColor DarkGray

$apiAppDisplayName = Read-WithDefault -Prompt 'Backend API app registration display name' -Default 'ApimSample.Api'
$appRoleValue = Read-WithDefault -Prompt 'App role value (used in token "roles" claim)' -Default 'Api.Access'
$appRoleDescription = Read-WithDefault -Prompt 'App role description' -Default 'Allows calling the ApimSample API.'
$swaggerAppDisplayName = Read-WithDefault -Prompt 'Client (Swagger/UI) app registration display name' -Default 'ApimSample.Swagger'

# --- 1. Ensure the API app registration exists ---------------------------------------------------
Write-Host ''
Write-Host "-- Backend API app registration: $apiAppDisplayName --" -ForegroundColor Cyan
$apiApp = az ad app list --display-name $apiAppDisplayName --query '[0]' -o json | ConvertFrom-Json
if (-not $apiApp) {
	Write-Host 'Not found. Creating...' -ForegroundColor Yellow
	$apiApp = az ad app create --display-name $apiAppDisplayName --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
	az ad app update --id $apiApp.appId --identifier-uris "api://$($apiApp.appId)" | Out-Null
	$apiApp = az ad app show --id $apiApp.appId -o json | ConvertFrom-Json
} else {
	Write-Host "Found existing app: $($apiApp.appId)" -ForegroundColor DarkGray
}
$apiAppId = $apiApp.appId

$apiSp = az ad sp list --filter "appId eq '$apiAppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $apiSp) {
	Write-Host 'Creating service principal for the API app...' -ForegroundColor Yellow
	$apiSp = az ad sp create --id $apiAppId -o json | ConvertFrom-Json
}
$apiSpId = $apiSp.id

# --- 2. Ensure the Api.Access app role exists on the API app --------------------------------------
Write-Host ''
Write-Host "-- App role: $appRoleValue --" -ForegroundColor Cyan
$existingRoles = az ad app show --id $apiAppId --query 'appRoles' -o json | ConvertFrom-Json
$role = $existingRoles | Where-Object { $_.value -eq $appRoleValue }
if (-not $role) {
	Write-Host 'Not found. Adding app role (allowedMemberTypes: User, Application)...' -ForegroundColor Yellow
	$newRoleId = [guid]::NewGuid().ToString()
	$newRole = @{
		allowedMemberTypes = @('User', 'Application')
		description        = $appRoleDescription
		displayName        = $appRoleValue
		id                 = $newRoleId
		isEnabled          = $true
		value              = $appRoleValue
	}
	$updatedRoles = @($existingRoles) + $newRole
	$body = @{ appRoles = $updatedRoles } | ConvertTo-Json -Depth 10 -Compress
	$bodyFile = New-TemporaryFile
	[IO.File]::WriteAllText($bodyFile.FullName, $body, [Text.UTF8Encoding]::new($false))
	az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$($apiApp.id)" --headers 'Content-Type=application/json' --body "@$($bodyFile.FullName)"
	Remove-Item $bodyFile -Force
	$roleId = $newRoleId
} else {
	Write-Host "Found existing app role: $($role.id)" -ForegroundColor DarkGray
	$roleId = $role.id
}

# --- 3. Ensure the Swagger/UI client app registration exists --------------------------------------
Write-Host ''
Write-Host "-- Client app registration: $swaggerAppDisplayName --" -ForegroundColor Cyan
$swaggerApp = az ad app list --display-name $swaggerAppDisplayName --query '[0]' -o json | ConvertFrom-Json
if (-not $swaggerApp) {
	Write-Host 'Not found. Creating (public client, Authorization Code + PKCE)...' -ForegroundColor Yellow
	$redirectUri = Read-WithDefault -Prompt 'Swagger UI redirect URI' -Default 'https://localhost:5001/swagger/oauth2-redirect.html'
	$swaggerApp = az ad app create --display-name $swaggerAppDisplayName --sign-in-audience AzureADMyOrg --is-fallback-public-client true --public-client-redirect-uris $redirectUri -o json | ConvertFrom-Json
} else {
	Write-Host "Found existing app: $($swaggerApp.appId)" -ForegroundColor DarkGray
}
$swaggerAppId = $swaggerApp.appId

$swaggerSp = az ad sp list --filter "appId eq '$swaggerAppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $swaggerSp) {
	Write-Host 'Creating service principal for the client app...' -ForegroundColor Yellow
	$swaggerSp = az ad sp create --id $swaggerAppId -o json | ConvertFrom-Json
}
$swaggerSpId = $swaggerSp.id

$createSecret = Read-Host 'Generate a new client secret for the client app now? (y/N)'
if ($createSecret -in @('y', 'Y', 'yes', 'Yes')) {
	$secretResult = az ad app credential reset --id $swaggerAppId --years 1 --query password -o tsv
	Write-Host "New client secret (copy it now, it will not be shown again):" -ForegroundColor Yellow
	Write-Host $secretResult -ForegroundColor Green
}

# --- 4. Assign Api.Access to the client app (needed for client-credentials calls) -----------------
Write-Host ''
Write-Host '-- App-role assignment: client app -> API --' -ForegroundColor Cyan
$existingAssignment = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo" --query "value[?principalId=='$swaggerSpId' && appRoleId=='$roleId']" -o json | ConvertFrom-Json
if ($existingAssignment) {
	Write-Host 'Already assigned.' -ForegroundColor DarkGray
} else {
	$graphToken = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
	$headers = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }
	$body = @{ principalId = $swaggerSpId; resourceId = $apiSpId; appRoleId = $roleId } | ConvertTo-Json -Compress
	Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo" -Headers $headers -Body $body | Out-Null
	Write-Host 'Assigned.' -ForegroundColor Green
}

# --- 5. Assign Api.Access to APIM's managed identity (post-deploy.ps1 step) ------------------------
Write-Host ''
Write-Host '-- App-role assignment: APIM managed identity -> API --' -ForegroundColor Cyan
$apimPrincipalId = Read-WithDefault -Prompt 'APIM managed identity object ID (blank to skip if APIM is not deployed yet)' -Default ''
if ($apimPrincipalId) {
	$existingApimAssignment = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo" --query "value[?principalId=='$apimPrincipalId' && appRoleId=='$roleId']" -o json | ConvertFrom-Json
	if ($existingApimAssignment) {
		Write-Host 'Already assigned.' -ForegroundColor DarkGray
	} else {
		$graphToken = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
		$headers = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }
		$body = @{ principalId = $apimPrincipalId; resourceId = $apiSpId; appRoleId = $roleId } | ConvertTo-Json -Compress
		Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo" -Headers $headers -Body $body | Out-Null
		Write-Host 'Assigned.' -ForegroundColor Green
	}
} else {
	Write-Host 'Skipped — re-run this script after deploy.ps1 with the APIM managed identity object ID from its output.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
[pscustomobject]@{
	ApiAppClientId      = $apiAppId
	ApiAppIdUri         = "api://$apiAppId"
	ApiServicePrincipal = $apiSpId
	AppRoleValue        = $appRoleValue
	AppRoleId           = $roleId
	SwaggerClientId     = $swaggerAppId
	SwaggerServicePrincipal = $swaggerSpId
} | Format-List

Write-Host 'Use ApiAppClientId and SwaggerClientId as apiAppClientId / swaggerClientAppId when running deploy.ps1.' -ForegroundColor Yellow
