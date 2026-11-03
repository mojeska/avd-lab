using 'main.bicep'

// Copy to lab.local.bicepparam (gitignored) and fill in your own values.
// Group object IDs: az ad group show -g "<group name>" --query id -o tsv

param prefix = 'avdlab'
param userGroupObjectId = '00000000-0000-0000-0000-000000000000'
param adminGroupObjectId = ''
param sessionHostCount = 1
param vmSize = 'Standard_D2s_v4'
param osDiskType = 'Standard_LRS'
param logDailyCapGb = '0.1'
param enrollInIntune = true
param shutdownTime = '1900'
param shutdownTimeZone = 'Pacific Standard Time'

param enableSingleSignOn = true
param enableScalingPlan = true

// AVD service principal object ID, for Start VM on Connect and the scaling plan:
// az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
param avdServicePrincipalObjectId = ''

// Read from the environment so it never lands in a file.
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')
