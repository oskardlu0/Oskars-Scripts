#####################################################################
# AVD Host Pool Automation Toolkit - Cloud Shell Edition
#
# Description:
#   Interactive PowerShell menu for managing Azure Virtual Desktop (AVD)
#   host pools directly from Azure Cloud Shell. Useful for automation,
#   maintenance, and troubleshooting common session host issues.
#
# Features:
#   - Fix "Unavailable" session hosts
#   - Reinstall AVD agents on any session host
#   - Reset local admin passwords (e.g., 'azureadmin')
#   - List assigned users per session host
#   - Detect expired or disabled Azure AD users
#
# Environment:
#   - Designed to run in Azure Cloud Shell (PowerShell)
#   - No installation required — all necessary modules preloaded
#
# Usage:
#   1. Set your Azure Subscription ID in the `$SubscriptionId` variable
#   2. Run the script in Azure Cloud Shell (PowerShell)
#   3. Follow the interactive menu
#
# Prerequisites:
#   - AVD permissions (Reader + Virtual Machine Contributor recommended)
#   - Ability to run Azure CLI and Az PowerShell cmdlets
#
# Notes:
#   - No credentials or secrets are stored
#   - Temp script files (like refresh-avd.ps1) are saved to `$HOME`
#
# Author:
#   Oskar Dlugolecki
#####################################################################


# Set subscription ID
$SubscriptionId = 'xxxxxx'  # enter sub ID here
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

function Show-MainMenu {
    Clear-Host
    Write-Host "================ AVD HostPool Manager ================" -ForegroundColor Cyan
    Write-Host "1) Fix agents on Unavailable hosts"
    Write-Host "2) Check old or expired users"
    Write-Host "3) Reset local admin password"
    Write-Host "4) List session hosts and assigned users"
    Write-Host "5) Reinstall agents on ANY hosts"
    Write-Host "0) Exit"
    Write-Host "======================================================="
}

while ($true) {
    Show-MainMenu
    $mainChoice = Read-Host "Select an option"
    switch ($mainChoice) {

        '1' {
            Clear-Host
            Write-Host "`n--- Fixing agents on Unavailable hosts ---`n" -ForegroundColor Yellow

            # Step 0: Select subscription
            Write-Host "Selecting subscription $SubscriptionId..."
            Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

            # Step 1: Choose a Host Pool
            $pools = Get-AzWvdHostPool
            for ($i = 0; $i -lt $pools.Count; $i++) {
                Write-Host "$($i+1)) $($pools[$i].Name)"
            }
            Write-Host "0) Return to Main Menu"
            $hpChoice = Read-Host "Select a Host Pool"
            if ($hpChoice -eq '0') { break }

            $pool          = $pools[[int]$hpChoice - 1]
            $ResourceGroup = $pool.ResourceGroupName
            $HostPoolName  = $pool.Name
            $ApiVersion    = '2024-04-03'

            Write-Host "`nHost Pool: $HostPoolName (RG: $ResourceGroup)" -ForegroundColor Cyan

            # Step 2: Get only Unavailable session hosts
            $path     = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=$ApiVersion"
            $response = Invoke-AzRest -Method GET -Path $path -ErrorAction Stop
            $hosts    = ($response.Content | ConvertFrom-Json).value
            $badHosts = $hosts | Where-Object { $_.properties.status -eq 'Unavailable' }

            if ($badHosts.Count -eq 0) {
                Write-Host "No unavailable hosts in this pool." -ForegroundColor Green
                Read-Host "Press Enter to return to Main Menu"
                break
            }

            # Step 3: Choose which Unavailable host(s)
            for ($i = 0; $i -lt $badHosts.Count; $i++) {
                $name = $badHosts[$i].name.Split('/')[-1]
                Write-Host "$($i+1)) $name"
            }
            Write-Host "$($badHosts.Count+1)) ALL"
            Write-Host "0) Return to Main Menu"
            $hChoice = Read-Host "Select host to repair"
            if ($hChoice -eq '0') { break }

            if ($hChoice -eq ($badHosts.Count+1).ToString()) {
                $targets = $badHosts
            } else {
                $targets = @($badHosts[[int]$hChoice - 1])
            }

            foreach ($h in $targets) {
                $SessionHostName = $h.name.Split('/')[-1]
                $VMName          = $SessionHostName

                Write-Host "`n=== Repairing $SessionHostName ===" -ForegroundColor Cyan

                # a) Grab assigned user
                $assignedUser = $null
                if ($h.properties.assignedUser) {
                    if ($h.properties.assignedUser -is [string]) {
                        $assignedUser = $h.properties.assignedUser
                    } elseif ($h.properties.assignedUser.userPrincipalName) {
                        $assignedUser = $h.properties.assignedUser.userPrincipalName
                    }
                }
                if ($null -ne $assignedUser -and $assignedUser -ne '') {
                    Write-Host "Assigned user: $assignedUser"
                } else {
                    Write-Host "Assigned user: <none>"
                }

                # b) Drain the host
                Write-Host " Step 1: Draining session host..."
                Remove-AzWvdSessionHost -ResourceGroupName $ResourceGroup `
                                       -HostPoolName    $HostPoolName `
                                       -Name            $SessionHostName -Force

                # c) Get/generate registration key
                Write-Host " Step 2: Getting registration key..."
                $token = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $ResourceGroup `
                                                           -HostPoolName    $HostPoolName
                if (-not $token.Token -or $token.ExpirationTime -lt (Get-Date).ToUniversalTime()) {
                    $expiry = (Get-Date).ToUniversalTime().AddHours(24).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
                    New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroup `
                                             -HostPoolName    $HostPoolName `
                                             -ExpirationTime  $expiry | Out-Null
                    $token = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $ResourceGroup `
                                                               -HostPoolName    $HostPoolName
                }
                $registrationKey = $token.Token

                # d) Ensure VM running
                Write-Host " Step 3: Ensuring VM is running..."
                $status = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses `
                          | Where-Object { $_.Code -like 'PowerState/*' } `
                          | Select-Object -ExpandProperty DisplayStatus
                if ($status -ne 'VM running') {
                    Write-Host "  VM is $status, starting..."
                    Start-AzVM -ResourceGroupName $ResourceGroup -Name $VMName | Out-Null
                    do {
                        Start-Sleep -Seconds 10
                        $status = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses `
                                  | Where-Object { $_.Code -like 'PowerState/*' } `
                                  | Select-Object -ExpandProperty DisplayStatus
                        Write-Host "   VM status: $status"
                    } until ($status -eq 'VM running')
                    Write-Host "  VM is now running."
                } else {
                    Write-Host "  VM already running."
                }

                # e) Push & run refresh script
                Write-Host " Step 4: Refreshing AVD agent..."
                $vmScript = @'
param([string] $HostPoolRegKey)
# Uninstall old agent & bootstrap
Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Remote Desktop Services Infrastructure Agent%'" |
  ForEach-Object { Start-Process msiexec.exe -ArgumentList "/x $($_.IdentifyingNumber) /qn" -Wait }
Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Remote Desktop Services Infrastructure Bootstrap%'" |
  ForEach-Object { Start-Process msiexec.exe -ArgumentList "/x $($_.IdentifyingNumber) /qn" -Wait }
# Download & install fresh
function Get-RedirectLocation([string] $u) {
  $r=[System.Net.HttpWebRequest]::Create($u); $r.Method='HEAD'; $r.AllowAutoRedirect=$false
  $rsp=$r.GetResponse(); $l=$rsp.Headers['Location']; $rsp.Close(); return $l
}
$AgentUrl=Get-RedirectLocation 'https://go.microsoft.com/fwlink/?linkid=2310011'
$BootUrl =Get-RedirectLocation 'https://go.microsoft.com/fwlink/?linkid=2311028'
Invoke-WebRequest -Uri $AgentUrl -OutFile C:\Temp\Agent.msi
Invoke-WebRequest -Uri $BootUrl  -OutFile C:\Temp\Bootstrap.msi
Start-Process msiexec.exe -ArgumentList "/i C:\Temp\Bootstrap.msi /qn" -Wait
Start-Process msiexec.exe -ArgumentList "/i C:\Temp\Agent.msi REGISTRATIONTOKEN=$HostPoolRegKey /qn" -Wait
Restart-Service -Name RDAgentBootloader -ErrorAction SilentlyContinue
Restart-Service -Name RDAgent         -ErrorAction SilentlyContinue
'@
                $remotePath = "$HOME\refresh-avd.ps1"
                $vmScript | Out-File -FilePath $remotePath -Encoding UTF8

                $vmRun = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup `
                                              -Name              $VMName `
                                              -CommandId         'RunPowerShellScript' `
                                              -ScriptPath        $remotePath `
                                              -Parameter         @{ HostPoolRegKey = $registrationKey } `
                                              -ErrorAction       Stop
                if ($vmRun.Status -eq 'Succeeded') {
                    Write-Host "  Agent refresh succeeded." -ForegroundColor Green
                } else {
                    Write-Host "  Agent refresh failed." -ForegroundColor Red
                }

                # f) Wait for healthy
                Write-Host " Step 5: Waiting for host health..."
                for ($i = 1; $i -le 40; $i++) {
                    Start-Sleep -Seconds 15
                    $check  = Invoke-AzRest -Method GET -Path $path -ErrorAction Stop
                    $single = ($check.Content | ConvertFrom-Json).value |
                              Where-Object { $_.name.Split('/')[-1] -eq $SessionHostName }
                    if ($single -and (
                         $single.properties.allowNewSession -or
                         ($single.properties.sessionHostHealthCheckResults |
                          Where-Object { $_.healthCheckResult -ne 'HealthCheckSucceeded' } |
                          Measure-Object).Count -eq 0)) {
                        Write-Host "  $SessionHostName is healthy." -ForegroundColor Green
                        break
                    }
                    Write-Host "   [$i/40] allowNewSession: $($single.properties.allowNewSession)"
                }

                # g) Re-assign user
                if ($assignedUser) {
                    Write-Host " Step 6: Re-assigning user '$assignedUser'..."
                    $patchPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$SessionHostName?api-version=$ApiVersion&force=true"
                    $body      = @{ properties = @{ assignedUser = $assignedUser } } | ConvertTo-Json -Depth 3
                    try {
                        Invoke-AzRest -Method PATCH -Path $patchPath -Payload $body -ErrorAction Stop | Out-Null
                        Write-Host "  User re-assigned." -ForegroundColor Green
                    } catch {
                        Write-Host "  Failed to re-assign user." -ForegroundColor Red
                    }
                }
            }

            Read-Host "`nAll done — press Enter to return to Main Menu"
            break
        }

        '2' {
            do {
                Write-Host "`nChecking for disabled or non-existent users in session hosts..." -ForegroundColor Cyan
                $hostPools = Get-AzWvdHostPool
                foreach ($pool in $hostPools) {
                    $ResourceGroup = $pool.ResourceGroupName
                    $HostPoolName = $pool.Name
                    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=2024-04-03"
                    $response = Invoke-AzRest -Method GET -Path $path -ErrorAction Stop
                    $hosts = ($response.Content | ConvertFrom-Json).value

                    foreach ($h in $hosts) {
                        $assignedUser = $h.properties.assignedUser
                        $hostName = $h.name.Split('/')[-1]

                        if ($assignedUser) {
                            $userPrincipal = if ($assignedUser -is [string]) { $assignedUser } else { $assignedUser.userPrincipalName }
                            $adUser = Get-AzADUser -UserPrincipalName $userPrincipal -ErrorAction SilentlyContinue

                            if (-not $adUser) {
                                Write-Host "$hostName - Assigned user not found in AAD: $userPrincipal" -ForegroundColor Yellow
                            } elseif ($adUser.AccountEnabled -eq $false) {
                                Write-Host "$hostName - User is disabled in AAD: $userPrincipal" -ForegroundColor Red
                            }
                        }
                    }
                }

                Write-Host "`n0) Return to Main Menu"
                $choice = Read-Host "Select an option"
            } while ($choice -ne '0')
        }

        '3' {
            # Reset Local Admin Password
            Write-Host "`n--- Reset Local Admin Password ---`n" -ForegroundColor Cyan
            $securePwd = Read-Host -AsSecureString "Enter new password for local user 'azureadmin' (new password in keeper)"
            $plainPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
            )
            Write-Host "Password saved for this session." -ForegroundColor Green

            while ($true) {
                Write-Host "`nSelect a Host Pool or return to Main Menu:`n" -ForegroundColor Gray
                $hostPools = Get-AzWvdHostPool
                for ($i = 0; $i -lt $hostPools.Count; $i++) {
                    Write-Host "$($i+1)) $($hostPools[$i].Name)"
                }
                Write-Host "0) Return to Main Menu"
                $hpChoice = Read-Host "Your choice"
                if ($hpChoice -eq '0') { break }
                
                $pool = $hostPools[[int]$hpChoice - 1]
                $sessions = Get-AzWvdSessionHost -ResourceGroupName $pool.ResourceGroupName -HostPoolName $pool.Name

                Write-Host "`nSelect a session host, ALL, or return to Main Menu:`n" -ForegroundColor Gray
                for ($i = 0; $i -lt $sessions.Count; $i++) {
                    $name = $sessions[$i].Name.Split('/')[-1]
                    Write-Host "$($i+1)) $name"
                }
                Write-Host "$($sessions.Count+1)) ALL"
                Write-Host "0) Return to Host Pool Menu"
                $hChoice = Read-Host "Your choice"

                if ($hChoice -eq '0') { continue }

                if ($hChoice -eq ($sessions.Count+1).ToString()) {
                    $targets = $sessions
                } else {
                    $targets = @($sessions[[int]$hChoice - 1])
                }

                az account set --subscription $SubscriptionId
                foreach ($t in $targets) {
                    $vmName = $t.Name.Split('/')[-1]
                    $rg = ($t.ResourceId -split '/')[4]
                    Write-Host "`nProcessing VM: $vmName (RG: $rg) ..." -ForegroundColor Yellow

                    $state = az vm get-instance-view --resource-group $rg --name $vmName `
                              --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv
                    if ($state -ne 'VM running') {
                        Write-Host " VM is $state. Starting..." -ForegroundColor DarkYellow
                        az vm start --resource-group $rg --name $vmName | Out-Null
                        az vm wait --resource-group $rg --name $vmName `
                          --custom "instanceView.statuses[?code=='PowerState/running']" --interval 10 --timeout 600
                        Write-Host " VM started." -ForegroundColor Green
                    }
                    az vm wait --resource-group $rg --name $vmName `
                      --custom "instanceView.statuses[?code=='ProvisioningState/succeeded']" --interval 10 --timeout 600

                    Write-Host "Resetting password on $vmName..." -NoNewline
                    az vm run-command invoke --resource-group $rg --name $vmName `
                      --command-id RunPowerShellScript `
                      --scripts "net user azureadmin $plainPwd" `
                      --only-show-errors -o none
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host " ✅" -ForegroundColor Green
                    } else {
                        Write-Host " ❌" -ForegroundColor Red
                    }
                }

                Read-Host "Press Enter to return to password menu"
            }
        }

        '4' {
            while ($true) {
                Write-Host "`n--- List Session Hosts & Users ---`n" -ForegroundColor Cyan
                $pools = Get-AzWvdHostPool
                for ($i = 0; $i -lt $pools.Count; $i++) {
                    Write-Host "$($i+1)) $($pools[$i].Name)"
                }
                Write-Host "0) Return to Main Menu"
                $choice = Read-Host "Select a host pool"
                if ($choice -eq '0') { break }

                $pool = $pools[[int]$choice - 1]
                $path = "/subscriptions/$SubscriptionId/resourceGroups/$($pool.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$($pool.Name)/sessionHosts?api-version=2024-04-03"
                $hosts = (Invoke-AzRest -Method GET -Path $path).Content |
                         ConvertFrom-Json |
                         Select-Object -Expand value

                Write-Host "`nSessionHost`tAssignedUser`tHealthStatus`n-----------`t-------------`t-------------" -ForegroundColor Green
                foreach ($h in $hosts) {
                    $name = $h.name.Split('/')[-1]
                    $user = if ($h.properties.assignedUser) {
                        if ($h.properties.assignedUser -is [string]) { $h.properties.assignedUser } else { $h.properties.assignedUser.userPrincipalName }
                    } else { '<none>' }
                    $status = $h.properties.status
                    Write-Host "$name`t$user`t$status"
                }

                Read-Host "Press Enter to return to session-list menu"
            }
        }
        '5' {
            Clear-Host
            Write-Host "`n--- Reinstall agents on ANY host (All Statuses) ---`n" -ForegroundColor Yellow

            # Step 0: Select subscription
            Write-Host "Selecting subscription $SubscriptionId..."
            Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

            # Step 1: Choose a Host Pool
            $pools = Get-AzWvdHostPool
            for ($i = 0; $i -lt $pools.Count; $i++) {
                Write-Host "$($i+1)) $($pools[$i].Name)"
            }
            Write-Host "0) Return to Main Menu"
            $hpChoice = Read-Host "Select a Host Pool"
            if ($hpChoice -eq '0') { break }

            $pool          = $pools[[int]$hpChoice - 1]
            $ResourceGroup = $pool.ResourceGroupName
            $HostPoolName  = $pool.Name
            $ApiVersion    = '2024-04-03'

            Write-Host "`nHost Pool: $HostPoolName (RG: $ResourceGroup)" -ForegroundColor Cyan

            # Step 2: Get all session hosts (no filtering)
            $path     = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=$ApiVersion"
            $response = Invoke-AzRest -Method GET -Path $path -ErrorAction Stop
            $allHosts = ($response.Content | ConvertFrom-Json).value

            if ($allHosts.Count -eq 0) {
                Write-Host "No hosts found in this pool." -ForegroundColor Yellow
                Read-Host "Press Enter to return to Main Menu"
                break
            }

            # Step 3: Let user choose one or all
            for ($i = 0; $i -lt $allHosts.Count; $i++) {
                $name = $allHosts[$i].name.Split('/')[-1]
                $status = $allHosts[$i].properties.status
                Write-Host "$($i+1)) $name  [$status]"
            }
            Write-Host "$($allHosts.Count+1)) ALL"
            Write-Host "0) Return to Main Menu"
            $hChoice = Read-Host "Select host to reinstall agent"
            if ($hChoice -eq '0') { break }

            if ($hChoice -eq ($allHosts.Count+1).ToString()) {
                $targets = $allHosts
            } else {
                $targets = @($allHosts[[int]$hChoice - 1])
            }

            foreach ($h in $targets) {
                $SessionHostName = $h.name.Split('/')[-1]
                $VMName          = $SessionHostName

                Write-Host "`n=== Repairing $SessionHostName ===" -ForegroundColor Cyan

                # a) Grab assigned user
                $assignedUser = $null
                if ($h.properties.assignedUser) {
                    if ($h.properties.assignedUser -is [string]) {
                        $assignedUser = $h.properties.assignedUser
                    } elseif ($h.properties.assignedUser.userPrincipalName) {
                        $assignedUser = $h.properties.assignedUser.userPrincipalName
                    }
                }
                if ($null -ne $assignedUser -and $assignedUser -ne '') {
                    Write-Host "Assigned user: $assignedUser"
                } else {
                    Write-Host "Assigned user: <none>"
                }

                # b) Drain the host
                Write-Host " Step 1: Draining session host..."
                Remove-AzWvdSessionHost -ResourceGroupName $ResourceGroup `
                                       -HostPoolName    $HostPoolName `
                                       -Name            $SessionHostName -Force

                # c) Get/generate registration key
                Write-Host " Step 2: Getting registration key..."
                $token = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $ResourceGroup `
                                                           -HostPoolName    $HostPoolName
                if (-not $token.Token -or $token.ExpirationTime -lt (Get-Date).ToUniversalTime()) {
                    $expiry = (Get-Date).ToUniversalTime().AddHours(24).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
                    New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroup `
                                             -HostPoolName    $HostPoolName `
                                             -ExpirationTime  $expiry | Out-Null
                    $token = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $ResourceGroup `
                                                               -HostPoolName    $HostPoolName
                }
                $registrationKey = $token.Token

                # d) Ensure VM running
                Write-Host " Step 3: Ensuring VM is running..."
                $status = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses `
                          | Where-Object { $_.Code -like 'PowerState/*' } `
                          | Select-Object -ExpandProperty DisplayStatus
                if ($status -ne 'VM running') {
                    Write-Host "  VM is $status, starting..."
                    Start-AzVM -ResourceGroupName $ResourceGroup -Name $VMName | Out-Null
                    do {
                        Start-Sleep -Seconds 10
                        $status = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses `
                                  | Where-Object { $_.Code -like 'PowerState/*' } `
                                  | Select-Object -ExpandProperty DisplayStatus
                        Write-Host "   VM status: $status"
                    } until ($status -eq 'VM running')
                    Write-Host "  VM is now running."
                } else {
                    Write-Host "  VM already running."
                }

                # e) Push & run refresh script
                Write-Host " Step 4: Refreshing AVD agent..."
                $vmScript = @'
param([string] $HostPoolRegKey)
Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Remote Desktop Services Infrastructure Agent%'" |
  ForEach-Object { Start-Process msiexec.exe -ArgumentList "/x $($_.IdentifyingNumber) /qn" -Wait }
Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Remote Desktop Services Infrastructure Bootstrap%'" |
  ForEach-Object { Start-Process msiexec.exe -ArgumentList "/x $($_.IdentifyingNumber) /qn" -Wait }
function Get-RedirectLocation([string] $u) {
  $r=[System.Net.HttpWebRequest]::Create($u); $r.Method='HEAD'; $r.AllowAutoRedirect=$false
  $rsp=$r.GetResponse(); $l=$rsp.Headers['Location']; $rsp.Close(); return $l
}
$AgentUrl=Get-RedirectLocation 'https://go.microsoft.com/fwlink/?linkid=2310011'
$BootUrl =Get-RedirectLocation 'https://go.microsoft.com/fwlink/?linkid=2311028'
Invoke-WebRequest -Uri $AgentUrl -OutFile C:\Temp\Agent.msi
Invoke-WebRequest -Uri $BootUrl  -OutFile C:\Temp\Bootstrap.msi
Start-Process msiexec.exe -ArgumentList "/i C:\Temp\Bootstrap.msi /qn" -Wait
Start-Process msiexec.exe -ArgumentList "/i C:\Temp\Agent.msi REGISTRATIONTOKEN=$HostPoolRegKey /qn" -Wait
Restart-Service -Name RDAgentBootloader -ErrorAction SilentlyContinue
Restart-Service -Name RDAgent         -ErrorAction SilentlyContinue
'@
                $remotePath = "$HOME\refresh-avd.ps1"
                $vmScript | Out-File -FilePath $remotePath -Encoding UTF8

                $vmRun = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup `
                                              -Name              $VMName `
                                              -CommandId         'RunPowerShellScript' `
                                              -ScriptPath        $remotePath `
                                              -Parameter         @{ HostPoolRegKey = $registrationKey } `
                                              -ErrorAction       Stop
                if ($vmRun.Status -eq 'Succeeded') {
                    Write-Host "  Agent refresh succeeded." -ForegroundColor Green
                } else {
                    Write-Host "  Agent refresh failed." -ForegroundColor Red
                }

                # f) Wait for healthy
                Write-Host " Step 5: Waiting for host health..."
                for ($i = 1; $i -le 40; $i++) {
                    Start-Sleep -Seconds 15
                    $check  = Invoke-AzRest -Method GET -Path $path -ErrorAction Stop
                    $single = ($check.Content | ConvertFrom-Json).value |
                              Where-Object { $_.name.Split('/')[-1] -eq $SessionHostName }
                    if ($single -and (
                         $single.properties.allowNewSession -or
                         ($single.properties.sessionHostHealthCheckResults |
                          Where-Object { $_.healthCheckResult -ne 'HealthCheckSucceeded' } |
                          Measure-Object).Count -eq 0)) {
                        Write-Host "  $SessionHostName is healthy." -ForegroundColor Green
                        break
                    }
                    Write-Host "   [$i/40] allowNewSession: $($single.properties.allowNewSession)"
                }

                # g) Re-assign user
                if ($assignedUser) {
                    Write-Host " Step 6: Re-assigning user '$assignedUser'..."
                    $patchPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$SessionHostName?api-version=$ApiVersion&force=true"
                    $body      = @{ properties = @{ assignedUser = $assignedUser } } | ConvertTo-Json -Depth 3
                    try {
                        Invoke-AzRest -Method PATCH -Path $patchPath -Payload $body -ErrorAction Stop | Out-Null
                        Write-Host "  User re-assigned." -ForegroundColor Green
                    } catch {
                        Write-Host "  Failed to re-assign user." -ForegroundColor Red
                    }
                }
            }

            Read-Host "`nAll done — press Enter to return to Main Menu"
            break
        }


        '0' {
            Write-Host "Exiting. Goodbye!" -ForegroundColor Cyan
            break
        }

        Default {
            Write-Host "Invalid selection, please choose a valid option." -ForegroundColor Red
            Pause
        }
    }
}
