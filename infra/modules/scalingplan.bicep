// Scaling plan: deallocates the session host whenever it has no sessions, at any time of
// day, so an idle lab doesn't run until the 19:00 auto-shutdown. Start VM on Connect starts
// it again. Hosts with a disconnected session keep running, so sign out rather than closing
// the window. Needs the AVD service principal to have Desktop Virtualization Power On Off
// Contributor (main.bicep assigns it).
//
// One schedule, every day: ramp-up 07:00 and peak 07:30 start nothing (minimum 0%);
// ramp-down from 08:00 and off-peak from 22:00 stop empty hosts. Users are never signed out.

param location string
param prefix string
param hostPoolId string
param timeZone string
param tags object

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2025-10-10' = {
  name: '${prefix}-sp'
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD lab'
    timeZone: timeZone
    hostPoolType: 'Pooled'
    schedules: [
      {
        name: 'every-day'
        daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
        rampUpStartTime: { hour: 7, minute: 0 }
        rampUpLoadBalancingAlgorithm: 'DepthFirst'
        rampUpMinimumHostsPct: 0
        rampUpCapacityThresholdPct: 90
        peakStartTime: { hour: 7, minute: 30 }
        peakLoadBalancingAlgorithm: 'DepthFirst'
        rampDownStartTime: { hour: 8, minute: 0 }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 0
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'This lab host will shut down when idle.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakStartTime: { hour: 22, minute: 0 }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolId
        scalingPlanEnabled: true
      }
    ]
  }
}
