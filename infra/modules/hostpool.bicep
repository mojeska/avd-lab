// Host pool, desktop application group, workspace, user assignment and diagnostics.

param location string
param prefix string
param userGroupObjectId string
param logAnalyticsWorkspaceId string
param startVMOnConnect bool
param enableSingleSignOn bool
param tokenExpiry string
param tags object

// enablerdsaadauth:i:1 turns on single sign-on with Microsoft Entra authentication. It
// works with MFA (including Security Defaults); the password-only sign-in loops on the
// password prompt when MFA is required. It also needs a one-time tenant setting, see README.
// targetisaadjoined:i:1 is the password-only fallback for clients that aren't Entra joined
// to this tenant (Mac, web, iOS, Android, home PCs); it's ignored when SSO is on.
var ssoProperty = enableSingleSignOn ? 'enablerdsaadauth:i:1;' : ''
var rdpProperties = '${ssoProperty}targetisaadjoined:i:1;audiocapturemode:i:1;audiomode:i:0;redirectclipboard:i:1;use multimon:i:1;drivestoredirect:s:;redirectprinters:i:0;devicestoredirect:s:;redirectcomports:i:0;redirectsmartcards:i:0;usbdevicestoredirect:s:'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-10-10' = {
  name: '${prefix}-hp'
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD lab'
    hostPoolType: 'Pooled'
    loadBalancerType: 'DepthFirst' // fill one host before starting the next
    maxSessionLimit: 4
    preferredAppGroupType: 'Desktop'
    validationEnvironment: true // gets agent updates first; fine for a lab
    startVMOnConnect: startVMOnConnect
    customRdpProperty: rdpProperties
    registrationInfo: {
      expirationTime: tokenExpiry
      registrationTokenOperation: 'Update'
    }
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2025-10-10' = {
  name: '${prefix}-dag'
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2025-10-10' = {
  name: '${prefix}-ws'
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD lab'
    applicationGroupReferences: [appGroup.id]
  }
}

// "Desktop Virtualization User" on the app group puts the desktop in the user's feed.
var desktopUserRole = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

resource feedAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appGroup.id, userGroupObjectId, desktopUserRole)
  scope: appGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopUserRole)
    principalId: userGroupObjectId
    principalType: 'Group'
  }
}

// 2021-05-01-preview is the newest version that supports categoryGroup.
#disable-next-line use-recent-api-versions
resource hostPoolDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: hostPool
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

#disable-next-line use-recent-api-versions
resource workspaceDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output hostPoolName string = hostPool.name
output hostPoolId string = hostPool.id
output workspaceName string = workspace.name
