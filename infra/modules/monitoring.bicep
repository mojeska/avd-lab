// Log Analytics workspace for AVD diagnostics (connections, errors, checkpoints).

param location string
param prefix string
param tags object

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
      dailyQuotaGb: 1 // lab guardrail
    }
  }
}

output workspaceId string = workspace.id
