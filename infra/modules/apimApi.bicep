// APIM API module: publishes the backend API through the parent APIM instance, links it to an
// existing product (e.g. the built-in "unlimited" product), and applies the zero-trust inbound
// policy (validate-azure-ad-token + authentication-managed-identity).

@description('Name of the parent API Management instance.')
param apimName string

@description('Identifier (path segment) used for this API within APIM, e.g. apimsample-api.')
param apiId string = 'apimsample-api'

@description('Display name of the API shown in the developer portal.')
param apiDisplayName string

@description('URL path suffix the API is exposed under, e.g. apimsample -> https://{gateway}/apimsample.')
param apiPath string

@description('Base URL of the backend the API forwards requests to (the Web App\'s default hostname).')
param backendServiceUrl string

@description('Existing product ID to associate this API with, e.g. "unlimited" (built-in).')
param productId string = 'unlimited'

@description('Raw policy XML applied to this API (inbound validate-azure-ad-token + authentication-managed-identity).')
param policyXml string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiId
  properties: {
	displayName: apiDisplayName
	path: apiPath
	protocols: [
	  'https'
	]
	serviceUrl: backendServiceUrl
	subscriptionRequired: true
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
	format: 'rawxml'
	value: policyXml
  }
}

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' existing = {
  parent: apim
  name: productId
}

resource productApiLink 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: apiId
  dependsOn: [
    api
  ]
}

output apiId string = api.id
output apiName string = api.name
