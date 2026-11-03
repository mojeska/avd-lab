# avd-lab

[![CI](https://github.com/mojeska/avd-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/mojeska/avd-lab/actions/workflows/ci.yml)

Azure Virtual Desktop lab in Bicep: a pooled host pool with **Entra-joined** session hosts (no domain controller), optional Intune enrollment, Log Analytics diagnostics, single sign-on, and cost guardrails (a scaling plan, auto-shutdown, Start VM on Connect, Standard HDD disks and a 0.1 GB/day log cap).

New to some of the terms? See the [Glossary](#glossary).

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
- VM quota for the size you pick. New pay-as-you-go subscriptions often have **0** cores for the Dsv5 family, which is why the default is `Standard_D2s_v4` (same price). Check with `az vm list-usage -l westus3 -o table`, or in the portal: search **Quotas** > **Compute**, filter to your region and look for the family (for example *Standard DSv4 Family vCPUs*). Request more from the same page.
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

**Portal:** there's no portal setting for this; it's only available through Microsoft Graph.

## Deploy

Each Azure CLI step below has a **Portal:** line with the same step in the [Azure portal](https://portal.azure.com) or the [Microsoft Entra admin center](https://entra.microsoft.com). The deployment itself needs the CLI or an extra build step, as explained there.

Sign in and pick the subscription:

```sh
az login
az account set --subscription "<subscription name or id>"
```

**Portal:** sign in at <https://portal.azure.com>. If you have more than one tenant, open **Settings** (gear icon) > **Directories + subscriptions** and switch to the lab tenant. Your subscriptions are under **Subscriptions**.

Get the user group's object ID (and the admin group's, if you use one):

```sh
az ad group show -g "AVD Users" --query id -o tsv
```

**Portal:** Entra admin center > **Groups** > **All groups** > *AVD Users* > **Overview** > **Object ID**.

Optional, for Start VM on Connect and the scaling plan: get the AVD service principal's object ID in your tenant:

```sh
az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
```

**Portal:** Entra admin center > **Enterprise apps** > **All applications**. Remove the *Application type* filter and search for `9cdead84-a844-4324-93f2-b2e6bb768d07` (named *Azure Virtual Desktop*, or *Windows Virtual Desktop* in older tenants). Copy its **Object ID**.

Copy the example parameters and fill in the IDs (`*.local.bicepparam` is gitignored):

```sh
cp infra/main.bicepparam infra/lab.local.bicepparam
```

**Portal:** no equivalent; the parameter file lives on your computer. If you deploy from the portal (below), you type the same values into its form instead.

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

**Portal:** **Virtual machines** > **Create** > **Azure virtual machine** > **Image** > **See all images**, search for *Microsoft 365 Apps* and open *Windows 11 Enterprise multi-session + Microsoft 365 Apps*. Its plan list shows the versions on offer (24H2 is `win11-24h2-avd-m365`). Cancel without creating anything.

Create the resource group:

```sh
az group create -n rg-avd-lab -l westus3
```

**Portal:** **Resource groups** > **Create**. Pick the subscription, name it `rg-avd-lab`, region *West US 3*, then **Review + create** > **Create**.

Set the local admin password for this shell only (PowerShell: `$env:AVD_LOCAL_ADMIN_PASSWORD = '...'`):

```sh
read -rs AVD_LOCAL_ADMIN_PASSWORD && export AVD_LOCAL_ADMIN_PASSWORD
```

**Portal:** no equivalent; the portal deployment form has its own password field.

Preview the changes:

```sh
az deployment group what-if -g rg-avd-lab -p infra/lab.local.bicepparam
```

**Portal:** the portal has no what-if. The closest is the validation that runs on **Review + create** in the custom deployment below, which catches errors but doesn't list the changes.

If what-if or the deployment says `Microsoft.DesktopVirtualization` isn't available in your region, add `param avdMetadataLocation = 'westus2'` (or another supported region) to your parameter file. The VMs stay in the resource group's region.

Deploy (about 15 minutes):

```sh
az deployment group create -g rg-avd-lab -p infra/lab.local.bicepparam
```

**Portal:** the portal can't read Bicep, so compile the template to ARM JSON first:

```sh
az bicep build -f infra/main.bicep --outfile ~/Downloads/avd-lab.json
```

Then search **Deploy a custom template** > **Build your own template in the editor** > **Load file**, pick `avd-lab.json` > **Save**. Choose the subscription and `rg-avd-lab`, fill in the same values as your parameter file (group IDs, VM size, password and so on) > **Review + create** > **Create**. Follow progress under the resource group's **Deployments**.

## Connect

Use **Windows App** (Windows, macOS, iOS, Android) or the web client at <https://windows.cloud.microsoft>. Add your work or school account, then open **Desktop** under **AVD lab**. With single sign-on you sign in once with Microsoft Entra (MFA included), then accept the **Allow remote desktop connection?** prompt (tick **Don't ask me again** for that device).

If the host is deallocated, Start VM on Connect starts it; the first connection takes a few minutes.

With `enableSingleSignOn = false`, the host pool falls back to `targetisaadjoined:i:1`: a password-only Windows sign-in for clients that aren't Entra joined to the tenant. That fails if MFA is required. See [Microsoft Entra joined session hosts](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts).

## Day to day

Check that the hosts are registered and available (the `desktopvirtualization` CLI extension has no session host commands, so this calls the API directly):

```sh
az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-avd-lab/providers/Microsoft.DesktopVirtualization/hostPools/avdlab-hp/sessionHosts?api-version=2024-04-03" --query "value[].{host:name, status:properties.status, sessions:properties.sessions}" -o table
```

**Portal:** **Azure Virtual Desktop** > **Host pools** > *avdlab-hp* > **Session hosts**. Check **Status** is *Available*, and see **Active sessions**.

When you're done, **sign out** of Windows (Start > your name > Sign out). Closing the window leaves a disconnected session, which keeps the scaling plan from stopping the host. Don't use **Shut down** inside Windows either: the VM stops but stays allocated, and compute keeps billing.

Stop (deallocate) the hosts by hand, so compute stops billing:

```sh
az vm deallocate --ids $(az vm list -g rg-avd-lab --query "[].id" -o tsv)
```

**Portal:** **Virtual machines** > tick the hosts > **Stop**. In the portal, Stop always deallocates.

Start them again (not needed if Start VM on Connect is on):

```sh
az vm start --ids $(az vm list -g rg-avd-lab --query "[].id" -o tsv)
```

**Portal:** **Virtual machines** > tick the hosts > **Start**.

Check whether a host is running or deallocated:

```sh
az vm list -g rg-avd-lab -d --query "[].{vm:name, power:powerState}" -o table
```

**Portal:** **Virtual machines**, **Status** column: *Running* or *Stopped (deallocated)*. *Stopped* without "deallocated" means compute is still billing.

Add hosts: raise `sessionHostCount` and redeploy (from the portal: **Redeploy** on the resource group's latest deployment, with a higher host count). Existing hosts are left alone.

Remove the whole lab:

```sh
az group delete -n rg-avd-lab
```

**Portal:** **Resource groups** > *rg-avd-lab* > **Delete resource group**, type the name to confirm > **Delete**.

> [!NOTE]
> Deleting the resource group doesn't remove the session hosts' **device objects** in Entra ID or Intune. Delete those by hand, or a rebuilt host with the same name may have trouble joining.
>
> **CLI:** find the device ID with `az rest --method get --url "https://graph.microsoft.com/v1.0/devices?\$filter=displayName eq 'avdlab-sh-0'&\$select=id,displayName"`, then `az rest --method delete --url "https://graph.microsoft.com/v1.0/devices/<id>"`.
>
> **Portal:** Entra admin center > **Devices** > **All devices** > search `avdlab-sh-0` > **Delete**. If you enrolled in Intune: Intune admin center > **Devices** > **All devices** > the host > **Delete**.

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

- **QuotaExceeded on the VM:** the subscription has no cores for that VM family in the region. Pick another size you have quota for (`az vm list-usage -l <region> -o table`; portal: **Quotas** > **Compute**) or request more quota from the same portal page.
- **Run command fails with "Download of Agent failed ... Unable to connect to the remote server":** the hosts have no outbound internet. Check `az network vnet subnet show -g rg-avd-lab --vnet-name avdlab-vnet -n sessionhosts --query defaultOutboundAccess` is `true` (portal: **Virtual networks** > *avdlab-vnet* > **Subnets** > *sessionhosts*: **Enable private subnet** must be unticked). If you change it, deallocate and start the VM, then redeploy.
- **Windows App keeps asking for the password:** MFA is required and single sign-on isn't on. Do the one-time tenant setting above and check the host pool RDP properties include `enablerdsaadauth:i:1` (CLI: `az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-avd-lab/providers/Microsoft.DesktopVirtualization/hostPools/avdlab-hp?api-version=2024-04-03" --query properties.customRdpProperty -o tsv`; portal: **Host pools** > *avdlab-hp* > **RDP Properties** > **Advanced**).
- **RoleAssignmentExists on redeploy:** the same role was assigned by hand before. Remove the manual assignment and redeploy. CLI: `az role assignment list -g rg-avd-lab -o table` to find it, then `az role assignment delete --ids <id>`. Portal: *rg-avd-lab* > **Access control (IAM)** > **Role assignments**, tick it > **Delete**.
- **Host shows Unavailable:** give it 5–10 minutes after deployment. Then check the run command output on the VM (`az vm run-command show -g rg-avd-lab --vm-name avdlab-sh-0 -n Register-AvdSessionHost --instance-view`), and `C:\Windows\Temp\Register-AvdSessionHost.log`.
- **Run command failed:** the registration token is only valid for 4 hours from the deployment. Redeploy, which issues a new token and runs registration again.
- **Sign-in fails on the host:** check the user has **Virtual Machine User Login** on the resource group, and see the MFA note above.
- **Logs:** Log Analytics workspace `avdlab-law`, tables `WVDConnections`, `WVDErrors` and `WVDCheckpoints`. Portal: *avdlab-law* > **Logs**.

## Roadmap

- FSLogix profiles on Azure Files with Microsoft Entra Kerberos (cloud-only identities).
- Custom image with Azure Compute Gallery.

## Tests

Offline checks (Bicep build and lint, script parse, help and PSScriptAnalyzer). CI runs them on every push:

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

## Glossary

**Application group (desktop application group):** decides what users see in their feed. This lab publishes one full desktop, named *Desktop*. Users get it through the **Desktop Virtualization User** role on the app group.

**ARM template:** Azure Resource Manager's own JSON format for describing resources. Bicep compiles to it, and the portal's **Deploy a custom template** reads it.

**Auto-shutdown:** a daily schedule on the VM (here 19:00) that deallocates it. It's a backup for the scaling plan, and runs once a day whatever is happening.

**Azure CLI (`az`):** Microsoft's command-line tool for Azure. Every `az ...` command in this README uses it.

**Azure Virtual Desktop (AVD):** Microsoft's service for running Windows desktops in Azure and connecting to them from anywhere. Its control plane (host pools, app groups, workspaces, brokering connections) is free; you pay for the VMs, disks and logs.

**Bicep:** a language for describing Azure resources as code. The `.bicep` files in `infra/` say what to build, and Azure works out how to get there. Running a deployment again updates the existing resources rather than creating copies.

**Conditional Access:** Entra ID policies that decide when sign-ins need extra checks, such as MFA. It needs Entra ID P1 or higher; Security Defaults is the free alternative.

**Deallocate:** stopping a VM so Azure releases its hardware, and compute billing stops. The disk is still billed. Shutting down from inside Windows stops the VM *without* deallocating it, so compute keeps billing.

**Default outbound access:** a free, implicit internet connection Azure used to give every VM. New subnets are now *private* (no default outbound access) unless the template says otherwise, so this lab turns it on explicitly. Microsoft is retiring it; the long-term replacement is a NAT gateway.

**Entra joined:** the VM is joined to Microsoft Entra ID instead of an on-premises Active Directory domain, so there's no domain controller to run. Users sign in with their Entra accounts.

**FSLogix:** keeps each user's profile in a file share so it follows them between hosts. Not used yet (see Roadmap); with one host, profiles stay on the VM's disk.

**Host pool:** a group of identical session hosts that AVD treats as one. *Pooled* means many users share each host; *personal* gives each user their own VM. This lab is pooled, with one host and up to 4 sessions.

**Intune:** Microsoft's device management service. Enrolling a host lets you push policies and apps to it. Optional here (`enrollInIntune`) and needs an Intune license.

**Log Analytics workspace:** where Azure stores logs so you can search them. You pay per GB taken in (*ingestion*) after the first 5 GB a month, and for keeping logs past 31 days (*retention*). The daily cap stops ingestion for the rest of the day once reached.

**Managed disk:** the VM's virtual hard disk. *Standard HDD* is cheapest, *Standard SSD* is faster, *Premium SSD* is for production. You pay for the disk's size tier, running or not.

**MFA (multifactor authentication):** a second check at sign-in, such as the Authenticator app. The password-only Windows sign-in can't do it, which is why this lab uses single sign-on.

**Microsoft Entra ID:** Microsoft's cloud identity service (formerly Azure Active Directory). It holds your users, groups, devices and app registrations, and handles sign-in.

**Microsoft Graph:** the single web API for Microsoft 365 and Entra ID data: users, groups, devices, apps and settings. Some settings, such as turning on Entra sign-in for RDP, have no portal page and can only be changed through Graph. You reach it from Graph PowerShell (`Connect-MgGraph`, `Update-Mg...`) or with `az rest` calls to `https://graph.microsoft.com`.

**Microsoft Graph PowerShell:** the PowerShell modules (`Microsoft.Graph.*`) that wrap Microsoft Graph in cmdlets.

**Multi-session:** an edition of Windows 11 Enterprise that only runs in Azure and lets several users sign in to the same VM at once. It's what makes a pooled host pool possible.

**NAT gateway:** an Azure resource that gives a subnet a fixed, managed route to the internet. The production replacement for default outbound access, at about $33 a month.

**NSG (network security group):** a firewall rule list for a subnet or network card. This lab's NSG has no inbound rules, so nothing on the internet can start a connection to the hosts.

**Object ID:** the unique ID of something in Entra ID (a user, group, device or service principal). The parameter file uses object IDs to say which group gets access.

**Parameter file (`.bicepparam`):** your values for a Bicep template, such as group IDs and VM size. `main.bicepparam` is the example; your own copy, `lab.local.bicepparam`, is ignored by Git so IDs never get committed.

**Quota:** how many vCPUs your subscription may run per VM family and region. New subscriptions often start at 0 for some families; you request more in the portal under **Quotas**.

**RDP (Remote Desktop Protocol) and RDP properties:** the protocol AVD uses to show you the desktop. RDP properties are settings on the host pool that control the connection, such as clipboard and audio redirection, or `enablerdsaadauth:i:1` for single sign-on.

**Registration token:** a short-lived key (4 hours here) that lets a new VM join the host pool. The deployment creates it and the run command uses it.

**Resource group:** a folder for Azure resources. Everything in this lab goes into `rg-avd-lab`, so deleting that group removes the whole lab.

**Reverse connect:** AVD hosts make outbound connections to the AVD service rather than accepting inbound ones, so they need no public IP and no open ports.

**Role assignment (Azure RBAC):** gives a user, group or service principal a role on a scope, such as *Virtual Machine User Login* on the resource group. RBAC stands for role-based access control.

**Run command:** a way to run a script inside a VM from Azure. This lab uses one to install the AVD agent and register the host.

**Scaling plan:** an AVD feature that starts and stops session hosts on a schedule and based on use. Here it deallocates the host whenever no sessions are left. Free.

**Security Defaults:** a free, all-or-nothing set of Entra ID protections, including MFA registration and MFA when sign-ins look risky. The alternative to Conditional Access.

**Service principal:** an app's identity in your tenant. The Azure Virtual Desktop service principal is what starts and stops your VMs, so it gets the Power On (Off) Contributor role.

**Session host:** a VM that users connect to. Here, `avdlab-sh-0`.

**Single sign-on (SSO):** you sign in once in the Windows App with your Entra account (MFA included), and Windows on the host trusts that sign-in instead of asking for a password again.

**Start VM on Connect:** AVD starts a deallocated host when a user connects. The first connection takes a few minutes.

**Subscription:** the Azure billing account resources live in. It belongs to one Entra tenant.

**Tenant:** your organization's instance of Microsoft Entra ID, such as `ms-bob.com`. Users, groups and devices live in the tenant; Azure resources live in subscriptions linked to it.

**Trusted Launch:** VM security features (Secure Boot and a virtual TPM) that protect against boot-level malware. Free, and recommended for Windows 11.

**VM size and family:** the size sets vCPUs, memory and price (for example `Standard_D2s_v4`: 2 vCPUs, 8 GiB). Sizes come in families (Dsv4, Dsv5, Basv2 and so on), and quota is set per family. *B-series* sizes are burstable: cheaper, but they slow down under long periods of heavy CPU use.

**VNet and subnet:** the lab's private network in Azure (`10.50.0.0/16`) and the slice of it the hosts use (`10.50.1.0/24`).

**What-if:** a preview of what a deployment would create, change or delete, without doing it.

**Windows App:** Microsoft's client for connecting to AVD and other cloud PCs, on Windows, macOS, iOS, Android and the web. It replaces the older Remote Desktop client.

**Workspace:** what users subscribe to in the Windows App. It lists the application groups they can use; here it shows as **AVD lab**.

## References

- [Add session hosts to a host pool](https://learn.microsoft.com/azure/virtual-desktop/add-session-hosts-host-pool) (agent install order and download links)
- [Microsoft Entra joined session hosts](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts)
- [Azure Virtual Desktop Landing Zone Accelerator](https://github.com/Azure/avdaccelerator)
