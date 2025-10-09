##########################################################################
# Azure Virtual Desktop (AVD) Session Host Agent Refresh & User Reassignment
#
# Description:
#   Automates the refresh of an AVD session host agent by draining the host,
#   restarting the VM if necessary, reinstalling agents, waiting for readiness,
#   and reassigning the user to the session host.
#
# Usage:
#   Run this script in Azure Cloud Shell or any PowerShell environment
#   with the Az module installed and authenticated.
#
# Configuration:
#   - Set $SubscriptionId to your Azure subscription ID.
#   - Set $ResourceGroup to the resource group containing your AVD resources.
#   - Set $HostPoolName to your AVD host pool name.
#   - Set $SessionHostName and $VMName to the specific session host and VM.
#
# Output:
#   Logs progress and status at each step.
##########################################################################

$SubscriptionId  = ''  # Your Azure subscription ID here
$ResourceGroup   = ''  # Resource group name here
$HostPoolName    = ''  # Host pool name here
$SessionHostName = ''  # Session host name here
$VMName          = ''  # VM name here (usually same as session host)
$ApiVersion      = '2024-04-03'

# 0) Select subscription
Write-Host "Step 0: Selecting subscription $SubscriptionId..."
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

# 1) Locate host pool and verify resource group
Write-Host "Step 1: Locating host pool '$HostPoolName'..."
$hp = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostPools' `
    -Name $HostPoolName -ErrorAction Stop

if ($hp.ResourceGroupName -ne $ResourceGroup) {
    throw "Host pool RG ($($hp.ResourceGroupName)) does not match configured RG ($ResourceGroup)"
}
Write-Host "Host pool confirmed in Resource Group: $ResourceGroup"

# 2) Fetch assigned user for the session host
Write-Host "Step 2: Retrieving assigned user for '$SessionHostName'..."
$path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=$ApiVersion"
$response = Invoke-AzRest -Method GET -Path $path -ErrorAction Stop
$hosts   = ($response.Content | ConvertFrom-Json).value
$entry   = $hosts | Where-Object { $_.name.Split('/')[-1] -ieq $SessionHostName }

if ($entry -and $entry.properties.assignedUser) {
    if ($entry.properties.assignedUser -is [string]) {
        $assignedUser = $entry.properties.assignedUser
    } elseif ($entry.properties.assignedUser.userPrincipalName) {
        $assignedUser = $entry.properties.assignedUser.userPrincipalName
    }
}
if ($null -ne $assignedUser -and $assignedUser -ne '') {
    Write-Host "Assigned user: $assignedUser"
} else {
    Write-Host "Assigned user: <none>"
}

# 3) Drain session host
Write-Host "Step 3: Draining session host..."
if ($entry) {
    Remove-AzWvdSessionHost -ResourceGroupName $ResourceGroup `
      -HostPoolName $HostPoolName -Name $SessionHostName -Force
}

# 4) Retrieve or generate registration key
Write-Host "Step 4: Retrieving/generating registration key..."
$token = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $ResourceGroup -HostPoolName $HostPoolName
if (-not $token.Token -or $token.ExpirationTime -lt (Get-Date).ToUniversalTime()) {
    $expiry = (Get-Date).ToUniversalTime().AddHours(24).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroup `
      -HostPoolName $HostPoolName -ExpirationTime $expiry | Out-Null
    $token = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $ResourceGroup -HostPoolName $HostPoolName
}
$registrationKey = $token.Token
Write-Host "Registration key acquired."

# 5) Ensure the VM is running
Write-Host "Step 5: Ensuring VM '$VMName' is running..."
$status = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses `
    | Where-Object { $_.Code -like 'PowerState/*' } `
    | Select-Object -ExpandProperty DisplayStatus
Write-Host "Current VM status: $status"
if ($status -ne 'VM running') {
    Write-Host "Starting VM..."
    Start-AzVM -ResourceGroupName $ResourceGroup -Name $VMName | Out-Null
    do {
        Start-Sleep -Seconds 10
        $status = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses `
            | Where-Object { $_.Code -like 'PowerState/*' } `
            | Select-Object -ExpandProperty DisplayStatus
        Write-Host "  VM status: $status"
    } until ($status -eq 'VM running')
    Write-Host "VM is now running."
}

# 6) Push and run agent refresh script on VM
Write-Host "Step 6: Refreshing AVD agent on VM..."

$vmScript = @'
param([string] $HostPoolRegKey)

# Uninstall existing AVD components
Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Remote Desktop Services Infrastructure Agent%'" |
  ForEach-Object { Start-Process msiexec.exe -ArgumentList "/x $($_.IdentifyingNumber) /qn" -Wait }

Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Remote Desktop Services Infrastructure Bootstrap%'" |
  ForEach-Object { Start-Process msiexec.exe -ArgumentList "/x $($_.IdentifyingNumber) /qn" -Wait }

# Download & install fresh agents
function Get-RedirectLocation([string] $u) {
  $r = [System.Net.HttpWebRequest]::Create($u); $r.Method='HEAD'; $r.AllowAutoRedirect=$false
  $rsp = $r.GetResponse(); $l = $rsp.Headers['Location']; $rsp.Close(); return $l
}
$AgentUrl = Get-RedirectLocation 'https://go.microsoft.com/fwlink/?linkid=2310011'
$BootUrl  = Get-RedirectLocation 'https://go.microsoft.com/fwlink/?linkid=2311028'
Invoke-WebRequest -Uri $AgentUrl -OutFile C:\Temp\Agent.msi
Invoke-WebRequest -Uri $BootUrl  -OutFile C:\Temp\Bootstrap.msi
Start-Process msiexec.exe -ArgumentList "/i C:\Temp\Bootstrap.msi /qn" -Wait
Start-Process msiexec.exe -ArgumentList "/i C:\Temp\Agent.msi REGISTRATIONTOKEN=$HostPoolRegKey /qn" -Wait

# Restart the AVD services
Restart-Service -Name RDAgentBootloader -ErrorAction SilentlyContinue
Restart-Service -Name RDAgent         -ErrorAction SilentlyContinue
'@

$remotePath = "$HOME/refresh-avd.ps1"
$vmScript | Out-File -FilePath $remotePath -Encoding UTF8

try {
    $vmRun = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroup `
        -Name              $VMName `
        -CommandId         'RunPowerShellScript' `
        -ScriptPath        $remotePath `
        -Parameter         @{ HostPoolRegKey = $registrationKey } `
        -ErrorAction       Stop

    if ($vmRun.Status -eq 'Succeeded') {
        Write-Host "Refresh succeeded."
    }
    else {
        Write-Host "Refresh failed."
    }
}
catch {
    Write-Host "Refresh failed."
}

# 7) Wait for session host readiness
Write-Host "Step 7: Waiting for session host readiness..."
$checkPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=$ApiVersion"
for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -Seconds 15
    $check  = Invoke-AzRest -Method GET -Path $checkPath -ErrorAction Stop
    $single = ($check.Content | ConvertFrom-Json).value |
              Where-Object { $_.name.Split('/')[-1] -ieq $SessionHostName }
    if ($single -and (
         $single.properties.allowNewSession -or
         ($single.properties.sessionHostHealthCheckResults |
          Where-Object { $_.healthCheckResult -ne 'HealthCheckSucceeded' } |
          Measure-Object).Count -eq 0)) {
        Write-Host "'${SessionHostName}' is healthy and ready."
        break
    }
    Write-Host "[$i/40] allowNewSession: $($single.properties.allowNewSession)"
}

# 8) Reassign user
Write-Host "Step 8: Re-assigning user to session host..."

$path = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts/${SessionHostName}?api-version=${ApiVersion}&force=true"
$body = @{ properties = @{ assignedUser = $assignedUser } } | ConvertTo-Json -Depth 3

try {
    Invoke-AzRest -Method PATCH -Path $path -Payload $body -ErrorAction Stop | Out-Null
    Write-Host "$assignedUser assigned to $SessionHostName"
} catch {
    Write-Host "Failed to assign $assignedUser to $SessionHostName"
}
