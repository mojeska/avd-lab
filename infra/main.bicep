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

@description('VM size for the session hosts. New pay-as-you-go subscriptions often have 0 quota for the Dsv5 family; check with: az vm list-usage -l <region> -o table')
param vmSize string = 'Standard_D2s_v4'

@description('OS disk type. Standard_LRS (HDD) is cheapest; StandardSSD_LRS boots and signs in faster for about $3.70/month more per host.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
param osDiskType string = 'Standard_LRS'

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

@description('Single sign-on with Microsoft Entra authentication. Needed when MFA is required (including Security Defaults). Also needs the one-time tenant setting in the README.')
param enableSingleSignOn bool = true

@description('Scaling plan that deallocates the host when it has no sessions. Needs avdServicePrincipalObjectId.')
param enableScalingPlan bool = true

@description('Log Analytics daily ingestion cap in GB, as a string (Bicep has no decimals).')
param logDailyCapGb string = '0.1'

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
    dailyCapGb: logDailyCapGb
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
    enableSingleSignOn: enableSingleSignOn
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
    osDiskType: osDiskType
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
// Lets the AVD service start deallocated hosts when a user connects (Power On Contributor),
// or also stop them for the scaling plan (Power On Off Contributor).
var powerOnContributorRole = '489581de-a3bd-480d-9518-53dea7416b33'
var powerOnOffContributorRole = '40c5ff49-9181-41f8-ae61-143b0e78555e'
var useScalingPlan = enableScalingPlan && !empty(avdServicePrincipalObjectId)
var avdServiceRole = useScalingPlan ? powerOnOffContributorRole : powerOnContributorRole

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
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, avdServiceRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', avdServiceRole)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

module scaling 'modules/scalingplan.bicep' = if (useScalingPlan) {
  name: 'scalingplan'
  dependsOn: [
    powerOn
  ]
  params: {
    location: avdMetadataLocation
    prefix: prefix
    hostPoolId: avd.outputs.hostPoolId
    timeZone: shutdownTimeZone
    tags: tags
  }
}

output hostPoolName string = avd.outputs.hostPoolName
output workspaceName string = avd.outputs.workspaceName
output sessionHosts array = [for i in range(0, sessionHostCount): sessionHosts[i].outputs.vmName]
