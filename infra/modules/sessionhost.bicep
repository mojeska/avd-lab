// One Entra-joined session host: VM, Entra join (and optional Intune enrollment),
// AVD agent registration, and a daily auto-shutdown.

param location string
param vmName string
param vmSize string
param imageReference object
param subnetId string
param localAdminName string
@secure()
param localAdminPassword string
param enrollInIntune bool
param hostPoolName string
param shutdownTime string
param shutdownTimeZone string
param tags object

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-10-10' existing = {
  name: hostPoolName
}

resource nic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned' // required by the Entra login extension
  }
  properties: {
    licenseType: 'Windows_Client' // AVD use rights from the user's M365/Windows Enterprise license
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS' // lab: Premium is recommended for production
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: localAdminName
      adminPassword: localAdminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// Joins the VM to the Entra tenant that owns the subscription. mdmId is Intune's
// app ID, which also enrolls the device in Intune.
resource entraJoin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: enrollInIntune ? {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    } : null
  }
}

// Installs the AVD agent and bootloader with the host pool's registration token.
resource registerHost 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = {
  parent: vm
  name: 'Register-AvdSessionHost'
  location: location
  dependsOn: [
    entraJoin
  ]
  properties: {
    source: {
      script: loadTextContent('../../scripts/Register-AvdSessionHost.ps1')
    }
    protectedParameters: [
      {
        name: 'RegistrationToken'
        value: hostPool.listRegistrationTokens().value[0].token
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (!empty(shutdownTime)) {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: shutdownTimeZone
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

output vmName string = vm.name
