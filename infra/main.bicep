// Azure Virtual Desktop lab: one pooled host pool with Entra-joined session hosts.
// Deploy into an empty resource group. See README.md for the commands.

targetScope = 'resourceGroup'

@description('Azure region for the VMs, network and logs.')
param location string = resourceGroup().location

@description('Region for the host pool, app group and workspace (AVD metadata). If the deployment says the resource type is not available in your region, set this to one that is, such as westus2 or eastus.')
param avdMetadataLocation string = location

@description('Short prefix for resource names (letters and numbers).')
@maxLength(8)
param prefix string = 'avdlab'

@description('Object ID of the Entra group whose members can use the desktop.')
param userGroupObjectId string

@description('Object ID of an Entra group whose members get local admin on the session hosts. Leave empty to skip.')
param adminGroupObjectId string = ''

@description('Number of session hosts.')
@minValue(1)
@maxValue(5)
param sessionHostCount int = 1

@description('VM size for the session hosts.')
param vmSize string = 'Standard_D2s_v5'

@description('Marketplace image. List current SKUs: az vm image list-skus -l <region> -p MicrosoftWindowsDesktop -f office-365 -o table')
param imageReference object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
  version: 'latest'
}

@description('Local administrator name on the session hosts (break-glass only; users sign in with Entra ID).')
param localAdminName string = 'avdadmin'

@description('Local administrator password.')
@secure()
param localAdminPassword string

@description('Enroll the session hosts in Intune. Needs an Intune license and automatic MDM enrollment set up in the tenant.')
param enrollInIntune bool = true

@description('Daily time (24h, HHmm) to shut the session hosts down. Empty disables auto-shutdown.')
param shutdownTime string = '1900'

@description('Windows time zone ID for the shutdown time.')
param shutdownTimeZone string = 'Pacific Standard Time'

@description('Object ID of the Azure Virtual Desktop service principal in your tenant, for Start VM on Connect. Empty disables it.')
param avdServicePrincipalObjectId string = ''

@description('Address space for the lab VNet.')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Subnet for the session hosts.')
param subnetPrefix string = '10.50.1.0/24'

@description('Used to set the registration token expiry. Leave the default.')
param baseTime string = utcNow()

var tags = {
  project: 'avd-lab'
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    prefix: prefix
    vnetAddressPrefix: vnetAddressPrefix
    subnetPrefix: subnetPrefix
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    prefix: prefix
    tags: tags
  }
}

module avd 'modules/hostpool.bicep' = {
  name: 'hostpool'
  params: {
    location: avdMetadataLocation
    prefix: prefix
    userGroupObjectId: userGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    startVMOnConnect: !empty(avdServicePrincipalObjectId)
    tokenExpiry: dateTimeAdd(baseTime, 'PT4H')
    tags: tags
  }
}

module sessionHosts 'modules/sessionhost.bicep' = [for i in range(0, sessionHostCount): {
  name: 'sessionhost-${i}'
  params: {
    location: location
    vmName: '${prefix}-sh-${i}'
    vmSize: vmSize
    imageReference: imageReference
    subnetId: network.outputs.subnetId
    localAdminName: localAdminName
    localAdminPassword: localAdminPassword
    enrollInIntune: enrollInIntune
    hostPoolName: avd.outputs.hostPoolName
    shutdownTime: shutdownTime
    shutdownTimeZone: shutdownTimeZone
    tags: tags
  }
}]

// Entra-joined hosts: users need "Virtual Machine User Login" to sign in to Windows,
// admins need "Virtual Machine Administrator Login". Scoped to this resource group.
var vmUserLoginRole = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var vmAdminLoginRole = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
// Lets the AVD service start deallocated hosts when a user connects.
var powerOnContributorRole = '489581de-a3bd-480d-9518-53dea7416b33'

resource userLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userGroupObjectId, vmUserLoginRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRole)
    principalId: userGroupObjectId
    principalType: 'Group'
  }
}

resource adminLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminGroupObjectId)) {
  name: guid(resourceGroup().id, adminGroupObjectId, vmAdminLoginRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmAdminLoginRole)
    principalId: adminGroupObjectId
    principalType: 'Group'
  }
}

resource powerOn 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdServicePrincipalObjectId)) {
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, powerOnContributorRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnContributorRole)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

output hostPoolName string = avd.outputs.hostPoolName
output workspaceName string = avd.outputs.workspaceName
output sessionHosts array = [for i in range(0, sessionHostCount): sessionHosts[i].outputs.vmName]
