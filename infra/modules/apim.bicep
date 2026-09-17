// Azure API Management module: Developer (or Premium) SKU instance with External VNet
// integration and a system-assigned managed identity. The managed identity is what the backend
// App Service trusts (see appService.bicep ApiSecurity__AllowedManagedIdentityObjectId) and what
// must be granted the Api.Access app role on the backend API app registration (see
// infra/entra-setup.ps1 — this cannot be done in Bicep/ARM; it requires Microsoft Graph).

@description('Azure region for all resources in this module.')
param location string

@description('Globally unique name of the API Management instance.')
param apimName string

@description('Email address of the API publisher (required by APIM, used for notifications).')
param publisherEmail string

@description('Organization name shown to API consumers.')
param publisherName string

@description('APIM SKU. Developer is for non-production; use Premium for production with VNet + zone redundancy.')
@allowed([
  'Developer'
  'Premium'
])
param skuName string = 'Developer'

@description('Number of scale units.')
param skuCapacity int = 1

@description('Resource ID of the subnet APIM is injected into (External VNet mode).')
param apimSubnetId string

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
	name: skuName
	capacity: skuCapacity
  }
  identity: {
	type: 'SystemAssigned'
  }
  properties: {
	publisherEmail: publisherEmail
	publisherName: publisherName
	virtualNetworkType: 'External'
	virtualNetworkConfiguration: {
	  subnetResourceId: apimSubnetId
	}
  }
}

output apimId string = apim.id
output apimName string = apim.name
output apimPrincipalId string = apim.identity.principalId
output apimGatewayUrl string = apim.properties.gatewayUrl
