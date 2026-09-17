// Zero-trust APIM + Private Endpoint architecture — main deployment template.
//
//   Internet Client -> Entra ID -> (Front Door WAF, optional) -> API Management
//     -> Private Endpoint -> App Service (public access disabled)
//
// This template provisions every Azure resource in that chain except the Entra ID app
// registrations and app-role assignments, which are not ARM/Bicep resources — run
// infra/entra-setup.ps1 (Microsoft Graph) before or after this deployment. See infra/README.md.
//
// Usage: infra/deploy.ps1 prompts for each parameter below (showing the default in brackets) and
// invokes `az deployment group create` with the values you choose.

@description('Azure region for every resource in this deployment.')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

@description('Name of the Virtual Network.')
param vnetName string = 'vnet-apimsample'

@description('Address space for the Virtual Network.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Name of the subnet API Management is injected into.')
param apimSubnetName string = 'snet-apim'

@description('Address prefix for the APIM subnet.')
param apimSubnetPrefix string = '10.10.1.0/24'

@description('Name of the subnet used for Private Endpoints.')
param privateEndpointSubnetName string = 'snet-privateendpoints'

@description('Address prefix for the Private Endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.10.2.0/24'

@description('Name of the Network Security Group applied to the APIM subnet.')
param nsgName string = 'nsg-apim'

// ---------------------------------------------------------------------------
// Backend App Service
// ---------------------------------------------------------------------------

@description('Name of the App Service Plan.')
param appServicePlanName string = 'apitest-asp'

@description('App Service Plan SKU (B1 minimum — required for Private Endpoint support).')
param appServicePlanSku string = 'B1'

@description('Globally unique name of the Web App hosting the backend API.')
param webAppName string = 'apittest'

@description('.NET runtime version for the Web App.')
param netFrameworkVersion string = 'v10.0'

@description('Name of the Private Endpoint connecting APIM\'s VNet to the Web App.')
param privateEndpointName string = 'pe-${webAppName}'

// ---------------------------------------------------------------------------
// API Management
// ---------------------------------------------------------------------------

@description('Globally unique name of the API Management instance.')
param apimName string = 'tomapim'

@description('Email address of the API publisher (required by APIM).')
param apimPublisherEmail string

@description('Organization name shown to API consumers in the developer portal.')
param apimPublisherName string = 'Contoso IT'

@description('APIM SKU. Developer is for non-production; use Premium for production.')
@allowed([
  'Developer'
  'Premium'
])
param apimSkuName string = 'Developer'

@description('Number of APIM scale units.')
param apimSkuCapacity int = 1

@description('Identifier (path segment) used for this API within APIM.')
param apiId string = 'apimsample-api'

@description('Display name of the API shown in the developer portal.')
param apiDisplayName string = 'ApimSample API'

@description('URL path suffix the API is exposed under, e.g. apimsample -> https://{gateway}/apimsample.')
param apiPath string = 'apimsample'

@description('Existing APIM product ID to associate this API with (built-in "unlimited" exists by default).')
param productId string = 'unlimited'

// ---------------------------------------------------------------------------
// Entra ID (App Registrations must already exist — see infra/entra-setup.ps1)
// ---------------------------------------------------------------------------

@description('Entra ID tenant ID.')
param tenantId string = subscription().tenantId

@description('Client ID (Application ID) of the backend API app registration.')
param apiAppClientId string

@description('Client ID of the Swagger/UI (or other confidential client) app registration allowed to call this API.')
param swaggerClientAppId string

@description('App role value required in the caller\'s token to access this API.')
param requiredAppRole string = 'Api.Access'

@description('Whether the backend enforces that only APIM\'s managed identity may call it directly.')
param enforceManagedIdentityTrust bool = true

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

var apiAppIdUri = 'api://${apiAppClientId}'
var apimGatewayOrigin = 'https://${apimName}.azure-api.net'

var policyXmlRaw = loadTextContent('policy/api-policy.template.xml')
var policyXml = replace(replace(replace(replace(policyXmlRaw,
  '__TENANT_ID__', tenantId),
  '__API_APP_ID_URI__', apiAppIdUri),
  '__API_CLIENT_ID__', apiAppClientId),
  '__SWAGGER_CLIENT_ID__', swaggerClientAppId)
var policyXmlFinal = replace(policyXml, '__REQUIRED_APP_ROLE__', requiredAppRole)

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
	location: location
	nsgName: nsgName
	vnetName: vnetName
	vnetAddressPrefix: vnetAddressPrefix
	apimSubnetName: apimSubnetName
	apimSubnetPrefix: apimSubnetPrefix
	privateEndpointSubnetName: privateEndpointSubnetName
	privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
  }
}

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
	location: location
	apimName: apimName
	publisherEmail: apimPublisherEmail
	publisherName: apimPublisherName
	skuName: apimSkuName
	skuCapacity: apimSkuCapacity
	apimSubnetId: network.outputs.apimSubnetId
  }
}

module appService 'modules/appService.bicep' = {
  name: 'appService'
  params: {
	location: location
	appServicePlanName: appServicePlanName
	appServicePlanSku: appServicePlanSku
	webAppName: webAppName
	netFrameworkVersion: netFrameworkVersion
	tenantId: tenantId
	apiAppClientId: apiAppClientId
	apiAppIdUri: apiAppIdUri
	requiredAppRole: requiredAppRole
	swaggerClientAppId: swaggerClientAppId
	apimManagedIdentityObjectId: apim.outputs.apimPrincipalId
	enforceManagedIdentityTrust: enforceManagedIdentityTrust
	allowedOrigins: [
	  apimGatewayOrigin
	]
  }
}

module privateEndpoint 'modules/privateEndpoint.bicep' = {
  name: 'privateEndpoint'
  params: {
	location: location
	privateEndpointName: privateEndpointName
	privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
	targetResourceId: appService.outputs.webAppId
	vnetId: network.outputs.vnetId
  }
}

module apimApi 'modules/apimApi.bicep' = {
  name: 'apimApi'
  params: {
	apimName: apim.outputs.apimName
	apiId: apiId
	apiDisplayName: apiDisplayName
	apiPath: apiPath
	backendServiceUrl: 'https://${appService.outputs.webAppDefaultHostName}'
	productId: productId
	policyXml: policyXmlFinal
  }
  dependsOn: [
	privateEndpoint
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output webAppName string = appService.outputs.webAppName
output webAppDefaultHostName string = appService.outputs.webAppDefaultHostName
output apimName string = apim.outputs.apimName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl
output apimManagedIdentityPrincipalId string = apim.outputs.apimPrincipalId
output apiGatewayCallUrl string = '${apim.outputs.apimGatewayUrl}/${apiPath}'
