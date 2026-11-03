# avd-lab

[![CI](https://github.com/mojeska/avd-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/mojeska/avd-lab/actions/workflows/ci.yml)

Azure Virtual Desktop lab in Bicep: a pooled host pool with **Entra-joined** session hosts (no domain controller), optional Intune enrollment, Log Analytics diagnostics, single sign-on, and cost guardrails (a scaling plan, auto-shutdown, Start VM on Connect, Standard HDD disks and a 0.1 GB/day log cap).

## Disclaimer

> [!WARNING]
> **Use at your own risk.** These templates and scripts are provided as-is, with no warranty or guarantee of any kind. The author accepts no liability for any damage, data loss, downtime, Azure charges or other problems that result from using them.
>
> Read and understand anything before you run it, do your own research, and test in a lab before using it in production. Deploying this creates billable Azure resources. See the [MIT License](LICENSE) for the full terms.

## What it deploys

| Resource | Notes |
| --- | --- |
| VNet, subnet, NSG | No public IPs, no inbound rules. AVD uses reverse connect (outbound 443 only). The subnet keeps default outbound access, so the hosts can reach the internet without a NAT gateway. |
| Host pool | Pooled, depth-first, 4 sessions per host, validation environment, single sign-on (`enablerdsaadauth:i:1`). |
| Desktop app group, workspace | The user group gets **Desktop Virtualization User** on the app group. |
| Session hosts | Windows 11 Enterprise multi-session + Microsoft 365 Apps, Trusted Launch, Standard HDD by default (`osDiskType`). Entra joined with `AADLoginForWindows`, registered with a VM run command ([`scripts/Register-AvdSessionHost.ps1`](scripts/Register-AvdSessionHost.ps1)). |
| Role assignments | **Virtual Machine User Login** for users, **Virtual Machine Administrator Login** for admins (optional), **Desktop Virtualization Power On Off Contributor** for the AVD service (Power On Contributor if the scaling plan is off; optional). |
| Log Analytics | Host pool and workspace diagnostics. 30-day retention (free), 0.1 GB/day cap (`logDailyCapGb`). |
| Scaling plan | Deallocates the host whenever it has no sessions; Start VM on Connect starts it again. Needs `avdServicePrincipalObjectId`. |
| Auto-shutdown | Daily, default 19:00 Pacific. A backup for the scaling plan. |

## Prerequisites

- An Azure subscription in the tenant the hosts should join, and Owner (or Contributor + User Access Administrator) on the resource group.
- Azure CLI with Bicep (`az bicep install`).
- An Entra group for the desktop users. Each user needs a license with AVD rights (Microsoft 365 E3/E5/A3/A5/F3/Business Premium, or Windows Enterprise E3/E5).
- For Intune enrollment: an Intune license, and **MDM user scope** set in Intune automatic enrollment. Otherwise set `enrollInIntune = false`.
- VM quota for the size you pick. New pay-as-you-go subscriptions often have **0** cores for the Dsv5 family, which is why the default is `Standard_D2s_v4` (same price). Check with `az vm list-usage -l westus3 -o table`.
- For single sign-on, a one-time tenant setting (below).

### One-time tenant setting for single sign-on

Single sign-on needs Microsoft Entra authentication for RDP turned on for two Microsoft service principals. Without it, or with `enableSingleSignOn = false`, the Windows sign-in on the host is password-only, which keeps asking for the password if MFA is required (including Security Defaults). In PowerShell with Microsoft Graph PowerShell installed:

```powershell
Connect-MgGraph -TenantId <your tenant> -Scopes "Application-RemoteDesktopConfig.ReadWrite.All" -NoWelcome
# Microsoft Remote Desktop and Windows Cloud Login
foreach ($appId in 'a4a365df-50f1-4397-bc59-1a1564b8bb9c', '270efc09-cd0d-444b-a71f-39af4910ec45') {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'"
    Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $sp.Id -IsRemoteDesktopProtocolEnabled
    Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $sp.Id | Select-Object IsRemoteDesktopProtocolEnabled
}
```

Both should show `True`.

## Deploy

Sign in and pick the subscription:

```sh
az login
az account set --subscription "<subscription name or id>"
```

Get the user group's object ID (and the admin group's, if you use one):

```sh
az ad group show -g "AVD Users" --query id -o tsv
```

Optional, for Start VM on Connect and the scaling plan: get the AVD service principal's object ID in your tenant:

```sh
az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
```

Copy the example parameters and fill in the IDs (`*.local.bicepparam` is gitignored):

```sh
cp infra/main.bicepparam infra/lab.local.bicepparam
```

The cost choices in the parameter file:

| Parameter | Default | Choice |
| --- | --- | --- |
| `vmSize` | `Standard_D2s_v4` ($0.096/h) | Any 2 vCPU, 8 GiB size you have quota for. 4 GiB sizes are too small for Windows 11 with Microsoft 365 Apps. |
| `osDiskType` | `Standard_LRS` (HDD, about $5.90/month) | `StandardSSD_LRS` (about $9.60/month) for faster boot and sign-in. The disk is billed even while the VM is deallocated. |
| `logDailyCapGb` | `'0.1'` | One host writes well under this. At the old 1 GB/day a noisy month could cost about $58. |
| `enableScalingPlan` | `true` | Stops the host when it's empty instead of waiting for 19:00. |
| `sessionHostCount` | `1` | Each extra host adds its running hours plus its disk. |

Check the current image SKUs in your region (update `imageReference` in `main.bicep` if `win11-24h2-avd-m365` is gone):

```sh
az vm image list-skus -l westus3 -p MicrosoftWindowsDesktop -f office-365 -o table
```

Create the resource group:

```sh
az group create -n rg-avd-lab -l westus3
```

Set the local admin password for this shell only (PowerShell: `$env:AVD_LOCAL_ADMIN_PASSWORD = '...'`):

```sh
read -rs AVD_LOCAL_ADMIN_PASSWORD && export AVD_LOCAL_ADMIN_PASSWORD
```

Preview the changes:

```sh
az deployment group what-if -g rg-avd-lab -p infra/lab.local.bicepparam
```

If what-if or the deployment says `Microsoft.DesktopVirtualization` isn't available in your region, add `param avdMetadataLocation = 'westus2'` (or another supported region) to your parameter file. The VMs stay in the resource group's region.

Deploy (about 15 minutes):

```sh
az deployment group create -g rg-avd-lab -p infra/lab.local.bicepparam
```

## Connect

Use **Windows App** (Windows, macOS, iOS, Android) or the web client at <https://windows.cloud.microsoft>. Add your work or school account, then open **Desktop** under **AVD lab**. With single sign-on you sign in once with Microsoft Entra (MFA included), then accept the **Allow remote desktop connection?** prompt (tick **Don't ask me again** for that device).

If the host is deallocated, Start VM on Connect starts it; the first connection takes a few minutes.

With `enableSingleSignOn = false`, the host pool falls back to `targetisaadjoined:i:1`: a password-only Windows sign-in for clients that aren't Entra joined to the tenant. That fails if MFA is required. See [Microsoft Entra joined session hosts](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts).

## Day to day

Check that the hosts are registered and available (the `desktopvirtualization` CLI extension has no session host commands, so this calls the API directly):

```sh
az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-avd-lab/providers/Microsoft.DesktopVirtualization/hostPools/avdlab-hp/sessionHosts?api-version=2024-04-03" --query "value[].{host:name, status:properties.status, sessions:properties.sessions}" -o table
```

When you're done, **sign out** of Windows (Start > your name > Sign out). Closing the window leaves a disconnected session, which keeps the scaling plan from stopping the host. Don't use **Shut down** inside Windows either: the VM stops but stays allocated, and compute keeps billing.

Stop (deallocate) the hosts by hand, so compute stops billing:

```sh
az vm deallocate --ids $(az vm list -g rg-avd-lab --query "[].id" -o tsv)
```

Start them again (not needed if Start VM on Connect is on):

```sh
az vm start --ids $(az vm list -g rg-avd-lab --query "[].id" -o tsv)
```

Check whether a host is running or deallocated:

```sh
az vm list -g rg-avd-lab -d --query "[].{vm:name, power:powerState}" -o table
```

Add hosts: raise `sessionHostCount` and redeploy. Existing hosts are left alone.

Remove the whole lab:

```sh
az group delete -n rg-avd-lab
```

> [!NOTE]
> Deleting the resource group doesn't remove the session hosts' **device objects** in Entra ID or Intune. Delete those by hand, or a rebuilt host with the same name may have trouble joining.

## Cost

Pay-as-you-go retail prices in westus3 (USD, November 2026) for one `Standard_D2s_v4` host with a Standard HDD disk. The AVD control plane, network, NSG and scaling plan are free; Log Analytics stays inside the 5 GB/month free allowance; the first 100 GB/month of outbound traffic is free.

| Use | Per day | Per week | Per month |
| --- | --- | --- | --- |
| Running 24/7 | $2.50 | $17.50 | about $76 |
| About 18 hours a week (scaling plan + Start VM on Connect) | $0.44 | $3.10 | about $13.40 |
| Deallocated (disk only) | $0.20 | $1.35 | about $5.90 |
| Resource group deleted | $0 | $0 | $0 |

Delete the resource group when you won't use the lab for a few weeks.

## Troubleshooting

- **QuotaExceeded on the VM:** the subscription has no cores for that VM family in the region. Pick another size you have quota for (`az vm list-usage -l <region> -o table`) or request more quota in the portal.
- **Run command fails with "Download of Agent failed ... Unable to connect to the remote server":** the hosts have no outbound internet. Check `az network vnet subnet show -g rg-avd-lab --vnet-name avdlab-vnet -n sessionhosts --query defaultOutboundAccess` is `true`. If you change it, deallocate and start the VM, then redeploy.
- **Windows App keeps asking for the password:** MFA is required and single sign-on isn't on. Do the one-time tenant setting above and check the host pool RDP properties include `enablerdsaadauth:i:1`.
- **RoleAssignmentExists on redeploy:** the same role was assigned by hand before. Remove the manual assignment (`az role assignment delete`) and redeploy.

- **Host shows Unavailable:** give it 5–10 minutes after deployment. Then check the run command output on the VM, and `C:\Windows\Temp\Register-AvdSessionHost.log`.
- **Run command failed:** the registration token is only valid for 4 hours from the deployment. Redeploy, which issues a new token and runs registration again.
- **Sign-in fails on the host:** check the user has **Virtual Machine User Login** on the resource group, and see the MFA note above.
- **Logs:** Log Analytics workspace `avdlab-law`, tables `WVDConnections`, `WVDErrors` and `WVDCheckpoints`.

## Roadmap

- FSLogix profiles on Azure Files with Microsoft Entra Kerberos (cloud-only identities).
- Custom image with Azure Compute Gallery.

## Tests

Offline checks (Bicep build and lint, script parse, help and PSScriptAnalyzer). CI runs them on every push:

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

## References

- [Add session hosts to a host pool](https://learn.microsoft.com/azure/virtual-desktop/add-session-hosts-host-pool) (agent install order and download links)
- [Microsoft Entra joined session hosts](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts)
- [Azure Virtual Desktop Landing Zone Accelerator](https://github.com/Azure/avdaccelerator)
