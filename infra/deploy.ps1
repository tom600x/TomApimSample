#Requires -Version 7.0
<#
.SYNOPSIS
	Interactively deploys the zero-trust APIM + Private Endpoint architecture defined in main.bicep.

.DESCRIPTION
	Prompts for every resource name/setting with a sensible default shown in [brackets] — press
	Enter to accept the default, or type a new value. Then runs `az deployment group create`
	(What-If first) against the target resource group.

	This script provisions Azure infrastructure only. It does NOT create Entra ID app
	registrations or app-role assignments — run entra-setup.ps1 for that, either before this
	script (to obtain apiAppClientId / swaggerClientAppId) or after (assigning APIM's managed
	identity, which this script's output prints for you).

.EXAMPLE
	./deploy.ps1
#>

[CmdletBinding()]
param()

function Read-WithDefault {
	param(
		[Parameter(Mandatory)][string]$Prompt,
		[string]$Default = '',
		[switch]$Required
	)
	while ($true) {
		$suffix = if ($Default) { " [$Default]" } else { '' }
		$value = Read-Host "$Prompt$suffix"
		if ([string]::IsNullOrWhiteSpace($value)) {
			if ($Default) { return $Default }
			if ($Required) { Write-Host 'This value is required.' -ForegroundColor Yellow; continue }
			return ''
		}
		return $value
	}
}

Write-Host '=== Zero-Trust APIM Architecture — Interactive Deployment ===' -ForegroundColor Cyan
Write-Host 'Press Enter on any prompt to accept the default shown in [brackets].' -ForegroundColor DarkGray
Write-Host ''

# --- Azure context -----------------------------------------------------------------------------
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
	Write-Host 'Not logged in. Launching az login...' -ForegroundColor Yellow
	az login | Out-Null
	$account = az account show | ConvertFrom-Json
}
$defaultSubscriptionId = $account.id
$defaultTenantId = $account.tenantId
Write-Host "Current subscription: $($account.name) ($defaultSubscriptionId)" -ForegroundColor DarkGray

$subscriptionId = Read-WithDefault -Prompt 'Subscription ID' -Default $defaultSubscriptionId
if ($subscriptionId -ne $defaultSubscriptionId) {
	az account set --subscription $subscriptionId
}
$tenantId = Read-WithDefault -Prompt 'Entra tenant ID' -Default $defaultTenantId

$resourceGroupName = Read-WithDefault -Prompt 'Resource group name' -Default 'APIM-RG'
$location = Read-WithDefault -Prompt 'Azure region' -Default 'centralus'

# --- Networking ---------------------------------------------------------------------------------
Write-Host ''
Write-Host '-- Networking --' -ForegroundColor Cyan
$vnetName = Read-WithDefault -Prompt 'Virtual network name' -Default 'vnet-apimsample'
$vnetAddressPrefix = Read-WithDefault -Prompt 'Virtual network address space' -Default '10.10.0.0/16'
$apimSubnetName = Read-WithDefault -Prompt 'APIM subnet name' -Default 'snet-apim'
$apimSubnetPrefix = Read-WithDefault -Prompt 'APIM subnet prefix' -Default '10.10.1.0/24'
$peSubnetName = Read-WithDefault -Prompt 'Private Endpoint subnet name' -Default 'snet-privateendpoints'
$peSubnetPrefix = Read-WithDefault -Prompt 'Private Endpoint subnet prefix' -Default '10.10.2.0/24'
$nsgName = Read-WithDefault -Prompt 'Network security group name' -Default 'nsg-apim'

# --- Backend App Service -------------------------------------------------------------------------
Write-Host ''
Write-Host '-- Backend App Service --' -ForegroundColor Cyan
$webAppName = Read-WithDefault -Prompt 'Web app name (must be globally unique)' -Default 'apittest'
$appServicePlanName = Read-WithDefault -Prompt 'App Service Plan name' -Default 'apitest-asp'
$appServicePlanSku = Read-WithDefault -Prompt 'App Service Plan SKU (B1 minimum)' -Default 'B1'
$netFrameworkVersion = Read-WithDefault -Prompt '.NET runtime version' -Default 'v10.0'

# --- API Management -------------------------------------------------------------------------------
Write-Host ''
Write-Host '-- API Management --' -ForegroundColor Cyan
$apimName = Read-WithDefault -Prompt 'APIM instance name (must be globally unique)' -Default 'tomapim'
$apimPublisherEmail = Read-WithDefault -Prompt 'APIM publisher email' -Required
$apimPublisherName = Read-WithDefault -Prompt 'APIM publisher organization name' -Default 'Contoso IT'
$apimSkuName = Read-WithDefault -Prompt 'APIM SKU (Developer or Premium)' -Default 'Developer'
$apiId = Read-WithDefault -Prompt 'APIM API identifier' -Default 'apimsample-api'
$apiDisplayName = Read-WithDefault -Prompt 'API display name' -Default 'ApimSample API'
$apiPath = Read-WithDefault -Prompt 'API URL path segment' -Default 'apimsample'
$productId = Read-WithDefault -Prompt 'Existing APIM product to attach the API to' -Default 'unlimited'

# --- Entra ID app registrations --------------------------------------------------------------------
Write-Host ''
Write-Host '-- Entra ID (app registrations must already exist; run entra-setup.ps1 if not) --' -ForegroundColor Cyan
$apiAppClientId = Read-WithDefault -Prompt 'Backend API app registration client ID' -Required
$swaggerClientAppId = Read-WithDefault -Prompt 'Swagger/UI client app registration client ID' -Required
$requiredAppRole = Read-WithDefault -Prompt 'Required app role value' -Default 'Api.Access'

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
[pscustomobject]@{
	Subscription      = $subscriptionId
	ResourceGroup     = $resourceGroupName
	Location          = $location
	VNet              = "$vnetName ($vnetAddressPrefix)"
	ApimSubnet        = "$apimSubnetName ($apimSubnetPrefix)"
	PrivateEndpointSubnet = "$peSubnetName ($peSubnetPrefix)"
	WebApp            = $webAppName
	AppServicePlan    = "$appServicePlanName ($appServicePlanSku)"
	Apim              = "$apimName ($apimSkuName)"
	ApiPath           = $apiPath
} | Format-List

$confirm = Read-Host 'Proceed with deployment? (y/N)'
if ($confirm -notin @('y', 'Y', 'yes', 'Yes')) {
	Write-Host 'Aborted.' -ForegroundColor Yellow
	return
}

# --- Ensure resource group exists ------------------------------------------------------------------
az group create --name $resourceGroupName --location $location --output none

$templateFile = Join-Path $PSScriptRoot 'main.bicep'
$paramArgs = @(
	"location=$location"
	"vnetName=$vnetName"
	"vnetAddressPrefix=$vnetAddressPrefix"
	"apimSubnetName=$apimSubnetName"
	"apimSubnetPrefix=$apimSubnetPrefix"
	"privateEndpointSubnetName=$peSubnetName"
	"privateEndpointSubnetPrefix=$peSubnetPrefix"
	"nsgName=$nsgName"
	"appServicePlanName=$appServicePlanName"
	"appServicePlanSku=$appServicePlanSku"
	"webAppName=$webAppName"
	"netFrameworkVersion=$netFrameworkVersion"
	"apimName=$apimName"
	"apimPublisherEmail=$apimPublisherEmail"
	"apimPublisherName=$apimPublisherName"
	"apimSkuName=$apimSkuName"
	"apiId=$apiId"
	"apiDisplayName=$apiDisplayName"
	"apiPath=$apiPath"
	"productId=$productId"
	"tenantId=$tenantId"
	"apiAppClientId=$apiAppClientId"
	"swaggerClientAppId=$swaggerClientAppId"
	"requiredAppRole=$requiredAppRole"
)

Write-Host ''
Write-Host 'Running what-if preview...' -ForegroundColor Cyan
az deployment group what-if `
	--resource-group $resourceGroupName `
	--template-file $templateFile `
	--parameters $paramArgs

$confirmDeploy = Read-Host 'Apply this deployment now? (y/N)'
if ($confirmDeploy -notin @('y', 'Y', 'yes', 'Yes')) {
	Write-Host 'Aborted after what-if preview.' -ForegroundColor Yellow
	return
}

Write-Host ''
Write-Host 'Deploying (this can take 30-45 minutes; APIM provisioning is the long pole)...' -ForegroundColor Cyan
$deployment = az deployment group create `
	--resource-group $resourceGroupName `
	--template-file $templateFile `
	--parameters $paramArgs `
	--output json | ConvertFrom-Json

if (-not $deployment) {
	Write-Host 'Deployment failed. See the error above.' -ForegroundColor Red
	return
}

$outputs = $deployment.properties.outputs
Write-Host ''
Write-Host '=== Deployment complete ===' -ForegroundColor Green
Write-Host "Web app:                     $($outputs.webAppName.value)"
Write-Host "APIM instance:               $($outputs.apimName.value)"
Write-Host "APIM gateway URL:            $($outputs.apimGatewayUrl.value)"
Write-Host "API call URL:                $($outputs.apiGatewayCallUrl.value)"
Write-Host "APIM managed identity (oid): $($outputs.apimManagedIdentityPrincipalId.value)"
Write-Host ''
Write-Host 'Next step: run ./entra-setup.ps1 and grant this managed identity the required app role,' -ForegroundColor Yellow
Write-Host 'then update ApiSecurity:AllowedManagedIdentityObjectId if it changed.' -ForegroundColor Yellow
