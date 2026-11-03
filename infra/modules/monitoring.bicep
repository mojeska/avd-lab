// Log Analytics workspace for AVD diagnostics (connections, errors, checkpoints).

param location string
param prefix string
param tags object

@description('Daily ingestion cap in GB, as a string because Bicep has no decimals (for example \'0.1\').')
param dailyCapGb string

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: json(dailyCapGb) // lab guardrail against surprise ingestion bills
    }
  }
}

output workspaceId string = workspace.id
