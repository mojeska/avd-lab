<#
.SYNOPSIS
    Installs the Azure Virtual Desktop agent and bootloader and registers this VM with a host pool.

.DESCRIPTION
    Runs on the session host as SYSTEM (Bicep passes it in as a VM run command). Installs the
    agent with the registration token first, then the bootloader, as Microsoft documents.
    If the bootloader service already exists the VM is already registered, so it exits.
    Log: C:\Windows\Temp\Register-AvdSessionHost.log

    Download links and install order:
    https://learn.microsoft.com/azure/virtual-desktop/add-session-hosts-host-pool#register-session-hosts-to-a-host-pool

.PARAMETER RegistrationToken
    Host pool registration token.

.EXAMPLE
    .\Register-AvdSessionHost.ps1 -RegistrationToken $token
    Registers this VM with the host pool the token belongs to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RegistrationToken
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is much faster without the progress bar
$log = Join-Path $env:SystemRoot 'Temp\Register-AvdSessionHost.log'
function Write-SetupLog([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -Path $log -Value $line
    Write-Output $line
}

if (Get-Service -Name RDAgentBootLoader -ErrorAction SilentlyContinue) {
    Write-SetupLog 'RDAgentBootLoader is already installed; this host is registered. Nothing to do.'
    return
}

$installers = [ordered]@{
    Agent      = 'https://go.microsoft.com/fwlink/?linkid=2310011'
    Bootloader = 'https://go.microsoft.com/fwlink/?linkid=2311028'
}
$work = Join-Path $env:SystemRoot 'Temp\AvdAgent'
New-Item -ItemType Directory -Path $work -Force | Out-Null

foreach ($name in $installers.Keys) {
    $file = Join-Path $work "$name.msi"
    for ($try = 1; $try -le 5; $try++) {
        try {
            Invoke-WebRequest -Uri $installers[$name] -OutFile $file -UseBasicParsing
            break
        } catch {
            Write-SetupLog "Download of $name failed (try $try): $($_.Exception.Message)"
            if ($try -eq 5) { throw }
            Start-Sleep -Seconds 20
        }
    }
    Unblock-File -Path $file

    $msiArgs = @('/i', "`"$file`"", '/quiet', '/norestart', '/l*v', "`"$work\$name.log`"")
    if ($name -eq 'Agent') { $msiArgs += "REGISTRATIONTOKEN=$RegistrationToken" }
    $p = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    # 3010 = success, restart required
    if ($p.ExitCode -notin 0, 3010) { throw "$name install failed with exit code $($p.ExitCode). See $work\$name.log" }
    Write-SetupLog "$name installed (exit code $($p.ExitCode))."
    # The verbose MSI log records the registration token, so keep it only on failure.
    if ($name -eq 'Agent') { Remove-Item -Path "$work\$name.log" -ErrorAction SilentlyContinue }
}

Write-SetupLog 'Registered. The host shows as Available in the host pool after a few minutes.'
