#####################################################################
# VMware Guest Software Inventory via HashiCorp Vault
#
# Filename:    Get-VMGuestSoftwareInventory.ps1
# Usage:       powershell.exe -File Get-VMGuestSoftwareInventory.ps1
#                 -VaultUsername <username>
#                 -VaultPassword <password>
#                 -Initials     <vault-kv-path>
#
# Description:
#   Authenticates to HashiCorp Vault via LDAP, retrieves per-domain
#   credentials from a KV secret, connects to vCenter, and runs a
#   guest script against every Windows VM to collect installed
#   software. Outputs a wide-format CSV: one row per VM, one column
#   per unique application, version as the cell value.
#
# Features:
#   - LDAP-based Vault authentication (no hardcoded credentials)
#   - Per-domain credential mapping built from Vault KV secrets
#   - Filters vCenter inventory to Windows guests only
#   - Reads installed software from both 32-bit and 64-bit registry
#     hives inside each guest via Invoke-VMScript
#   - Deduplicates applications per VM
#   - Wide-format CSV: VMs as rows, applications as columns
#   - Gracefully skips VMs with no FQDN, unknown domains, or errors
#   - Auto-creates output directory if it does not exist
#
# Environment:
#   - Designed to run on a Windows machine with VMware PowerCLI
#   - Requires HashiCorp Vault CLI (vault.exe) in PATH
#   - Requires network access to Vault and vCenter
#
# Usage:
#   1. Set your Vault address, KV mount, vCenter server, and domain
#      mappings in the configuration block below
#   2. Ensure vault.exe is available in your PATH
#   3. Run from an elevated PowerShell session, passing your Vault
#      credentials and KV path as parameters
#
# Prerequisites:
#   - VMware PowerCLI module installed
#   - HashiCorp Vault CLI installed and in PATH
#   - LDAP account with access to the relevant Vault KV path
#   - vCenter account with VM read + guest operations permissions
#   - VMware Tools running on each target guest VM
#
# Notes:
#   - No credentials or secrets are stored on disk
#   - VAULT_TOKEN environment variable is cleared before each run
#   - VMs in domains not present in the credential map are skipped
#   - Guest script runs in the context of the supplied domain credential
#
# Author:
#   Oskar Dlugolecki
#####################################################################

#####################################################################
# PARAMETERS — Supplied at runtime, do not hardcode
#####################################################################

param(
    [Parameter(Mandatory)]
    [string]$VaultUsername,

    [Parameter(Mandatory)]
    [string]$VaultPassword,

    # KV path within the mount (e.g. your initials or environment name)
    [Parameter(Mandatory)]
    [string]$KVPath,

    [Parameter(Mandatory = $false)]
    [string]$CSVPath = "C:\Temp\InstalledSoftwareInventory.csv"
)

#####################################################################
# CONFIGURATION — Edit these values before running
#####################################################################

# HashiCorp Vault address
$VaultAddr = "http://vault.example.com:8200/"

# Vault KV mount name
$VaultMount = "my-kv-mount"

# vCenter server FQDN
$vCenterServer = "vcenter.example.com"

# Map of AD domain suffixes to the Vault KV secret key names for
# that domain's credentials. Keys must match the domain suffix of
# the VM guest FQDN as reported by VMware Tools.
# The credential values are retrieved from Vault at runtime.
$DomainCredMap = @{
    "domain1.example.com" = @{ UserKey = "domain1_user"; PwdKey = "domain1_pwd" }
    "domain2.example.com" = @{ UserKey = "domain2_user"; PwdKey = "domain2_pwd" }
    "domain3.example.com" = @{ UserKey = "domain3_user"; PwdKey = "domain3_pwd" }
}

#####################################################################
# SCRIPT — Do not edit below this line
#####################################################################

Import-Module VMware.VimAutomation.Core -ErrorAction Stop

# --- STEP 1: AUTHENTICATE TO VAULT AND RETRIEVE SECRETS ---

Write-Host "1/5: Clearing any existing VAULT_TOKEN"
Remove-Item Env:VAULT_TOKEN -ErrorAction SilentlyContinue

$env:VAULT_ADDR = $VaultAddr

Write-Host "1/5: Logging into Vault as '$VaultUsername' ..."
$loginJson = vault login -method=ldap -path=ldap -format=json `
    username=$VaultUsername password=$VaultPassword

try {
    $login = $loginJson | ConvertFrom-Json
    $token = $login.auth.client_token
    if (-not $token) { throw "No token returned from Vault login." }
    Write-Host "   ✓ Obtained Vault token."
} catch {
    Write-Error "ERROR: Failed Vault login or no token returned. $_"
    exit 1
}

$env:VAULT_TOKEN = $token

Write-Host "2/5: Fetching secrets from $VaultMount/$KVPath ..."
$raw = vault kv get -format=json -mount=$VaultMount $KVPath

try {
    $obj  = $raw | ConvertFrom-Json
    $data = $obj.data.data
    Write-Host "   ✓ Retrieved Vault KV data."
} catch {
    Write-Error "ERROR: Failed to parse Vault KV JSON. $_"
    exit 1
}

# Build domain-to-credential map from Vault secrets
$domainsToCred = @{}
foreach ($domain in $DomainCredMap.Keys) {
    $userKey = $DomainCredMap[$domain].UserKey
    $pwdKey  = $DomainCredMap[$domain].PwdKey
    $user    = $data.$userKey
    $pwd     = $data.$pwdKey
    if ($user -and $pwd) {
        $domainsToCred[$domain] = New-Object System.Management.Automation.PSCredential(
            $user,
            (ConvertTo-SecureString $pwd -AsPlainText -Force)
        )
    } else {
        Write-Warning "Vault secret missing keys '$userKey' or '$pwdKey' for domain '$domain' — skipping."
    }
}

# --- STEP 2: CONNECT TO VCENTER ---

$vcCred = $domainsToCred.Values | Select-Object -First 1   # use whichever cred covers vCenter
# If vCenter uses a dedicated credential, retrieve it from Vault separately
# and replace $vcCred here.

Write-Host "`n3/5: Connecting to vCenter '$vCenterServer' ..."
try {
    Connect-VIServer -Server $vCenterServer -Credential $vcCred -ErrorAction Stop | Out-Null
    Write-Host "   ✓ Connected to vCenter."
} catch {
    Write-Error "✗ Failed to connect to vCenter: $_"
    exit 1
}

# --- STEP 3: ENUMERATE WINDOWS VMs ---

Write-Host "`n4/5: Retrieving all VMs and filtering for Windows guests ..."
$vmsAll = Get-VM | Sort-Object Name
$vms    = $vmsAll | Where-Object { $_.Guest.OSFullName -like "*Windows*" }

if (-not $vms) {
    Write-Host "No Windows VMs found in vCenter. Exiting."
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
    exit 0
}

Write-Host "   ✓ Found $($vms.Count) Windows VM(s).`n"

$allVmResults = @()
$vmIndex      = 0

foreach ($vm in $vms) {
    $vmIndex++
    Write-Host "Processing VM #$vmIndex of $($vms.Count): '$($vm.Name)' ..." -ForegroundColor Cyan

    $fqdn = $vm.Guest.HostName
    if ([string]::IsNullOrWhiteSpace($fqdn)) {
        Write-Host "   • Skipping '$($vm.Name)': no FQDN reported." -ForegroundColor Yellow
        continue
    }

    $parts = $fqdn.Split('.')
    if ($parts.Count -lt 2) {
        Write-Host "   • Skipping '$($vm.Name)': FQDN does not contain a domain suffix." -ForegroundColor Yellow
        continue
    }

    $fullDomain = ($parts[1..($parts.Count - 1)] -join '.').ToLower()
    Write-Host "   • Guest FQDN: $fqdn → Domain: $fullDomain"

    if (-not $domainsToCred.ContainsKey($fullDomain)) {
        Write-Host "   • Skipping '$($vm.Name)': domain '$fullDomain' not in credentials mapping." -ForegroundColor Yellow
        continue
    }

    $guestCred = $domainsToCred[$fullDomain]

    # Guest script: reads installed software from both registry hives
    $guestScript = @'
$ErrorActionPreference = "SilentlyContinue"
$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$appList = @()
foreach ($keyPath in $uninstallPaths) {
    Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DisplayName) {
            $appList += [PSCustomObject]@{
                Name    = $_.DisplayName
                Version = $_.DisplayVersion
            }
        }
    }
}
$appList = $appList | Sort-Object Name -Unique
foreach ($app in $appList) {
    $name = $app.Name.Replace("`n", " ").Replace("`r", " ")
    Write-Output "$name|$($app.Version)"
}
'@

    try {
        $liveVM       = Get-VM -Id $vm.Id
        $invokeResult = Invoke-VMScript `
            -VM            $liveVM `
            -GuestCredential $guestCred `
            -ScriptText    $guestScript `
            -ScriptType    PowerShell `
            -ErrorAction   Stop

        $trimmedOutput = $invokeResult.ScriptOutput.Trim()
        Write-Host "   • Raw ScriptOutput length: $($trimmedOutput.Length)"

        if ([string]::IsNullOrWhiteSpace($trimmedOutput)) {
            Write-Host "   • No output from guest script; skipping." -ForegroundColor Yellow
            continue
        }

        $appHash = @{}
        foreach ($line in ($trimmedOutput -split "`r?`n")) {
            if ($line -match "^(.+)\|(.*)$") {
                $appName = $matches[1].Trim()
                $ver     = $matches[2].Trim()
                if (-not $appHash.ContainsKey($appName)) {
                    $appHash[$appName] = $ver
                }
            }
        }

        Write-Host "   ✓ VM '$($vm.Name)' → found $($appHash.Count) app(s)." -ForegroundColor Green

        $allVmResults += [PSCustomObject]@{
            VMName   = $vm.Name
            Domain   = $fullDomain
            AppTable = $appHash
        }
    } catch {
        Write-Warning "   • Error processing VM '$($vm.Name)': $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Warning "     InnerException: $($_.Exception.InnerException.Message)"
        }
        continue
    }

    Write-Host ""
}

# --- STEP 4: DISCONNECT FROM VCENTER ---

Write-Host "`n5/5: Disconnecting from vCenter ..."
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
Write-Host "   ✓ Disconnected.`n"

# --- STEP 5: BUILD AND EXPORT WIDE-FORMAT CSV ---

Write-Host "Building final CSV ..."

if (-not $allVmResults -or $allVmResults.Count -eq 0) {
    Write-Warning "No application data collected from any VM. Exiting without writing CSV."
    exit 0
}

$allAppNames = $allVmResults.AppTable.Keys | Sort-Object -Unique
Write-Host "   ✓ Total unique applications across all VMs: $($allAppNames.Count)"

$csvObjects = @()
foreach ($vmResult in $allVmResults) {
    $orderedProps = [Ordered]@{
        VMName = $vmResult.VMName
        Domain = $vmResult.Domain
    }
    foreach ($app in $allAppNames)               { $orderedProps[$app] = "" }
    foreach ($app in $vmResult.AppTable.Keys)    { $orderedProps[$app] = $vmResult.AppTable[$app] }
    $csvObjects += New-Object PSObject -Property $orderedProps
}

$folder = Split-Path $CSVPath
if (-not (Test-Path $folder)) {
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    Write-Host "   • Created output folder: $folder"
}

$csvObjects | Export-Csv -Path $CSVPath -NoTypeInformation
Write-Host "   ✓ CSV written: $CSVPath" -ForegroundColor Green
Write-Host "`nAll done!`n"
