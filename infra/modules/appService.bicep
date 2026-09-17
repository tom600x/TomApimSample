// App Service module: Windows App Service Plan + Web App running the backend API.
//
// Public network access is disabled from the start; the app is reachable only through the
// Private Endpoint created by the privateEndpoint module. The app trusts only bearer tokens
// issued to Azure API Management's managed identity (see ApiSecurity__AllowedManagedIdentityObjectId).

@description('Azure region for all resources in this module.')
param location string

@description('Name of the App Service Plan.')
param appServicePlanName string

// Cheapest-SKU validation (Microsoft Learn, "App Service Private Endpoint overview", checked against
// current docs): Private Endpoints are supported only on Basic, Standard, PremiumV2/V3/V4, IsolatedV2
// and Functions Premium plans. Free, Shared, and Consumption plans are NOT supported. B1 (Basic, 1 core)
// is therefore the cheapest SKU that satisfies the "public access disabled, reachable only via Private
// Endpoint" requirement -- do not downgrade below B1.
@description('App Service Plan SKU. B1 is the cheapest tier that supports Private Endpoints.')
@allowed([
  'B1'
  'B2'
  'B3'
  'S1'
  'S2'
  'S3'
  'P1v3'
  'P2v3'
  'P3v3'
])
param appServicePlanSku string = 'B1'

@description('Globally unique name of the Web App hosting the backend API.')
param webAppName string

@description('.NET runtime version, e.g. v10.0.')
param netFrameworkVersion string = 'v10.0'

@description('Entra ID tenant ID.')
param tenantId string

@description('Client ID (Application ID) of the backend API app registration.')
param apiAppClientId string

@description('Application ID URI of the backend API app registration, e.g. api://<client-id>.')
param apiAppIdUri string

@description('App role value required to call this API.')
param requiredAppRole string = 'Api.Access'

@description('Client ID of the Swagger/UI app registration used for interactive testing.')
param swaggerClientAppId string

@description('Object ID (principal ID) of the Azure API Management managed identity that is trusted as the only caller.')
param apimManagedIdentityObjectId string

@description('Whether to enforce that only APIM\'s managed identity may call this API.')
param enforceManagedIdentityTrust bool = true

@description('Origins allowed to call this API directly (normally only the APIM gateway hostname).')
param allowedOrigins array

resource appServicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: appServicePlanName
  location: location
  sku: {
	name: appServicePlanSku
  }
  properties: {
	reserved: false
  }
}

resource webApp 'Microsoft.Web/sites@2024-11-01' = {
  name: webAppName
  location: location
  properties: {
	serverFarmId: appServicePlan.id
	httpsOnly: true
	publicNetworkAccess: 'Disabled'
	siteConfig: {
	  netFrameworkVersion: netFrameworkVersion
	  minTlsVersion: '1.2'
	  ftpsState: 'Disabled'
	  alwaysOn: true
	  http20Enabled: true
	  appSettings: [
		{
		  name: 'AzureAd__Instance'
		  value: 'https://login.microsoftonline.com/'
		}
		{
		  name: 'AzureAd__TenantId'
		  value: tenantId
		}
		{
		  name: 'AzureAd__ClientId'
		  value: apiAppClientId
		}
		{
		  name: 'AzureAd__Audience'
		  value: apiAppIdUri
		}
		{
		  name: 'ApiSecurity__RequiredAppRole'
		  value: requiredAppRole
		}
		{
		  name: 'ApiSecurity__SwaggerClientId'
		  value: swaggerClientAppId
		}
		{
		  name: 'ApiSecurity__AllowedManagedIdentityObjectId'
		  value: apimManagedIdentityObjectId
		}
		{
		  name: 'ApiSecurity__EnforceManagedIdentityTrust'
		  value: string(enforceManagedIdentityTrust)
		}
		{
		  name: 'ApiSecurity__AllowedOrigins__0'
		  value: length(allowedOrigins) > 0 ? allowedOrigins[0] : ''
		}
	  ]
	}
  }
}

output webAppId string = webApp.id
output webAppName string = webApp.name
output webAppDefaultHostName string = webApp.properties.defaultHostName
