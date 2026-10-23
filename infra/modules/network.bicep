// VNet and subnet for the session hosts. No public IPs and no inbound rules:
// AVD uses reverse connect, so the hosts only need outbound HTTPS.

param location string
param prefix string
param vnetAddressPrefix string
param subnetPrefix string
param tags object

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: '${prefix}-sessionhosts-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'sessionhosts'
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output subnetId string = vnet.properties.subnets[0].id
