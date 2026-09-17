// Private Endpoint module: connects the Web App to the Private Endpoint subnet and wires up
// the privatelink.azurewebsites.net private DNS zone so APIM (and anything else in the VNet)
// resolves the app's hostname to its private IP instead of its public IP.

@description('Azure region for all resources in this module.')
param location string

@description('Name prefix used for the Private Endpoint and its NIC.')
param privateEndpointName string

@description('Resource ID of the subnet the Private Endpoint NIC is created in.')
param privateEndpointSubnetId string

@description('Resource ID of the Web App (or other PaaS resource) to connect privately.')
param targetResourceId string

@description('Resource ID of the Virtual Network, used to link the private DNS zone.')
param vnetId string

@description('Name of the private DNS zone. Defaults to the Web Apps zone.')
param privateDnsZoneName string = 'privatelink.azurewebsites.net'

@description('Sub-resource (group ID) of the target resource. "sites" for Web Apps.')
param groupId string = 'sites'

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: privateEndpointName
  location: location
  properties: {
	subnet: {
	  id: privateEndpointSubnetId
	}
	privateLinkServiceConnections: [
	  {
		name: '${privateEndpointName}-connection'
		properties: {
		  privateLinkServiceId: targetResourceId
		  groupIds: [
			groupId
		  ]
		}
	  }
	]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${privateDnsZoneName}-link'
  location: 'global'
  properties: {
	registrationEnabled: false
	virtualNetwork: {
	  id: vnetId
	}
  }
}

resource privateEndpointDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
	privateDnsZoneConfigs: [
	  {
		name: privateDnsZoneName
		properties: {
		  privateDnsZoneId: privateDnsZone.id
		}
	  }
	]
  }
}

output privateEndpointId string = privateEndpoint.id
output networkInterfaceId string = privateEndpoint.properties.networkInterfaces[0].id
