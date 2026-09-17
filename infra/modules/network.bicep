// Network module: NSG + VNet with an APIM subnet and a Private Endpoint subnet.
//
// The NSG rules below are the minimum Microsoft requires for API Management to run inside a
// VNet in External mode (docs: "Network configuration for API Management"):
//   - Inbound 3443 from the ApiManagement service tag: control-plane / management endpoint.
//   - Inbound 443 from Internet: client traffic reaching the gateway (External mode only).
//   - Inbound 6390 from AzureLoadBalancer: Azure's load balancer health probes.
// Outbound traffic is left to the NSG's default allow rules (AllowVnetOutBound /
// AllowInternetOutBound). If your organization applies a deny-by-default outbound NSG or Azure
// Firewall, add the additional outbound rules documented at https://aka.ms/apim-vnet-config
// (Storage, SQL, Key Vault, Azure Monitor, Azure AD, Event Hub).

@description('Azure region for all resources in this module.')
param location string

@description('Name of the Network Security Group applied to the APIM subnet.')
param nsgName string

@description('Name of the Virtual Network.')
param vnetName string

@description('Address space for the Virtual Network, e.g. 10.10.0.0/16.')
param vnetAddressPrefix string

@description('Name of the subnet delegated to API Management.')
param apimSubnetName string

@description('Address prefix for the APIM subnet, e.g. 10.10.1.0/24.')
param apimSubnetPrefix string

@description('Name of the subnet used for Private Endpoints.')
param privateEndpointSubnetName string

@description('Address prefix for the Private Endpoint subnet, e.g. 10.10.2.0/24.')
param privateEndpointSubnetPrefix string

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
	securityRules: [
	  {
		name: 'AllowApimManagement'
		properties: {
		  priority: 100
		  direction: 'Inbound'
		  access: 'Allow'
		  protocol: 'Tcp'
		  sourcePortRange: '*'
		  destinationPortRange: '3443'
		  sourceAddressPrefix: 'ApiManagement'
		  destinationAddressPrefix: 'VirtualNetwork'
		}
	  }
	  {
		name: 'AllowGatewayHttps'
		properties: {
		  priority: 110
		  direction: 'Inbound'
		  access: 'Allow'
		  protocol: 'Tcp'
		  sourcePortRange: '*'
		  destinationPortRange: '443'
		  sourceAddressPrefix: 'Internet'
		  destinationAddressPrefix: 'VirtualNetwork'
		}
	  }
	  {
		name: 'AllowLbHealthProbe'
		properties: {
		  priority: 120
		  direction: 'Inbound'
		  access: 'Allow'
		  protocol: 'Tcp'
		  sourcePortRange: '*'
		  destinationPortRange: '6390'
		  sourceAddressPrefix: 'AzureLoadBalancer'
		  destinationAddressPrefix: 'VirtualNetwork'
		}
	  }
	]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
	addressSpace: {
	  addressPrefixes: [
		vnetAddressPrefix
	  ]
	}
	subnets: [
	  {
		name: apimSubnetName
		properties: {
		  addressPrefix: apimSubnetPrefix
		  networkSecurityGroup: {
			id: nsg.id
		  }
		}
	  }
	  {
		name: privateEndpointSubnetName
		properties: {
		  addressPrefix: privateEndpointSubnetPrefix
		  privateEndpointNetworkPolicies: 'Disabled'
		}
	  }
	]
  }
}

output vnetId string = vnet.id
output apimSubnetId string = '${vnet.id}/subnets/${apimSubnetName}'
output privateEndpointSubnetId string = '${vnet.id}/subnets/${privateEndpointSubnetName}'
