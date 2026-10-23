# avd-lab

[![CI](https://github.com/mojeska/avd-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/mojeska/avd-lab/actions/workflows/ci.yml)

Azure Virtual Desktop lab in Bicep: a pooled host pool with **Entra-joined** session hosts (no domain controller), optional Intune enrollment, Log Analytics diagnostics, and cost guardrails (auto-shutdown, Start VM on Connect, a 1 GB/day log cap).

## Disclaimer

> [!WARNING]
> **Use at your own risk.** These templates and scripts are provided as-is, with no warranty or guarantee of any kind. The author accepts no liability for any damage, data loss, downtime, Azure charges or other problems that result from using them.
>
> Read and understand anything before you run it, do your own research, and test in a lab before using it in production. Deploying this creates billable Azure resources. See the [MIT License](LICENSE) for the full terms.

## What it deploys

| Resource | Notes |
| --- | --- |
| VNet, subnet, NSG | No public IPs, no inbound rules. AVD uses reverse connect (outbound 443 only). |
| Host pool | Pooled, depth-first, 4 sessions per host, validation environment. |
| Desktop app group, workspace | The user group gets **Desktop Virtualization User** on the app group. |
| Session hosts | Windows 11 Enterprise multi-session + Microsoft 365 Apps, Trusted Launch, Standard SSD. Entra joined with `AADLoginForWindows`, registered with a VM run command ([`scripts/Register-AvdSessionHost.ps1`](scripts/Register-AvdSessionHost.ps1)). |
| Role assignments | **Virtual Machine User Login** for users, **Virtual Machine Administrator Login** for admins (optional), **Desktop Virtualization Power On Contributor** for the AVD service (optional). |
| Log Analytics | Host pool and workspace diagnostics. 30-day retention, 1 GB/day cap. |
| Auto-shutdown | Daily, default 19:00 Pacific. |

## Prerequisites

- An Azure subscription in the tenant the hosts should join, and Owner (or Contributor + User Access Administrator) on the resource group.
- Azure CLI with Bicep (`az bicep install`).
- An Entra group for the desktop users. Each user needs a license with AVD rights (Microsoft 365 E3/E5/A3/A5/F3/Business Premium, or Windows Enterprise E3/E5).
- For Intune enrollment: an Intune license, and **MDM user scope** set in Intune automatic enrollment. Otherwise set `enrollInIntune = false`.

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

Optional, for Start VM on Connect: get the AVD service principal's object ID in your tenant:

```sh
az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
```

Copy the example parameters and fill in the IDs (`*.local.bicepparam` is gitignored):

```sh
cp infra/main.bicepparam infra/lab.local.bicepparam
```

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

Use **Windows App** (Windows, macOS, iOS, Android) or the web client at <https://windows.cloud.microsoft>. Sign in with a member of the user group. The host pool sets `targetisaadjoined:i:1`, so clients that aren't Entra joined to the tenant can connect with a user name and password.

> [!NOTE]
> If Conditional Access requires MFA, exclude the **Azure Windows VM Sign-In** app from that policy (or set up single sign-on), or the Windows sign-in on the host fails. See [Microsoft Entra joined session hosts](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts).

## Day to day

Check that the hosts are registered and available (the CLI offers to install the `desktopvirtualization` extension the first time):

```sh
az desktopvirtualization sessionhost list -g rg-avd-lab --host-pool-name avdlab-hp --query "[].{host:name, status:status, sessions:sessions}" -o table
```

Stop (deallocate) the hosts when you're done, so compute stops billing:

```sh
az vm deallocate --ids $(az vm list -g rg-avd-lab --query "[].id" -o tsv)
```

Start them again (not needed if Start VM on Connect is on):

```sh
az vm start --ids $(az vm list -g rg-avd-lab --query "[].id" -o tsv)
```

Add hosts: raise `sessionHostCount` and redeploy. Existing hosts are left alone.

Remove the whole lab:

```sh
az group delete -n rg-avd-lab
```

> [!NOTE]
> Deleting the resource group doesn't remove the session hosts' **device objects** in Entra ID or Intune. Delete those by hand, or a rebuilt host with the same name may have trouble joining.

## Troubleshooting

- **Host shows Unavailable:** give it 5–10 minutes after deployment. Then check the run command output on the VM, and `C:\Windows\Temp\Register-AvdSessionHost.log`.
- **Run command failed:** the registration token is only valid for 4 hours from the deployment. Redeploy, which issues a new token and runs registration again.
- **Sign-in fails on the host:** check the user has **Virtual Machine User Login** on the resource group, and see the MFA note above.
- **Logs:** Log Analytics workspace `avdlab-law`, tables `WVDConnections`, `WVDErrors` and `WVDCheckpoints`.

## Roadmap

- FSLogix profiles on Azure Files with Microsoft Entra Kerberos (cloud-only identities).
- Single sign-on (Entra authentication for RDP).
- Scaling plan instead of auto-shutdown.
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
