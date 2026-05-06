#####################################################################
# Bulk Proxy Settings Reader — All Local User Profiles
#
# Filename:    Get-AllUsersProxySettings.ps1
# Usage:       powershell.exe -File Get-AllUsersProxySettings.ps1
#
# Description:
#   Iterates every real user profile on the local machine and reads
#   WinInet proxy settings from each user's NTUSER.DAT registry hive.
#   Users do not need to be logged on. Useful for auditing proxy
#   configuration drift across all accounts on a machine.
#
# Features:
#   - Automatically discovers all non-system profiles under C:\Users
#   - Mounts each NTUSER.DAT hive temporarily to read proxy settings
#   - Displays ProxyEnable, ProxyServer, and AutoConfigURL per user
#   - Detects and skips hives that are locked or already in use
#   - Always attempts hive unload in a finally block to prevent leaks
#   - Gracefully handles missing or inaccessible NTUSER.DAT files
#
# Environment:
#   - Designed to run on any Windows machine
#   - No additional modules required
#
# Usage:
#   1. Optionally adjust $usersPath if profiles live outside C:\Users
#   2. Add any additional system account names to the exclusion list
#   3. Run from an elevated PowerShell session (required to mount
#      registry hives with reg load)
#
# Prerequisites:
#   - Must be run as Administrator
#
# Notes:
#   - No credentials or secrets are stored
#   - Hives for currently logged-on users will be skipped as they
#     are locked by the active session
#   - Settings reflect WinInet/IE proxy config, which is also used
#     by many applications that do not manage their own proxy
#
# Author:
#   Oskar Dlugolecki
#####################################################################

#####################################################################
# CONFIGURATION — Edit these values before running
#####################################################################

# Root path where user profiles are stored
$usersPath = "C:\Users"

# Profiles to skip — add any additional system or service accounts
$excludedProfiles = @(
    "Default",
    "Default User",
    "Public",
    "All Users",
    "desktop.ini",
    "WDAGUtilityAccount"
)

#####################################################################
# SCRIPT — Do not edit below this line
#####################################################################

$mountRoot   = "HKU"
$mountPrefix = "TempProxy_"

# Discover all real user profiles
$userProfiles = Get-ChildItem -Path $usersPath -Directory |
                Where-Object { $_.Name -notin $excludedProfiles }

foreach ($profile in $userProfiles) {
    $username   = $profile.Name
    $ntuserPath = "$($profile.FullName)\NTUSER.DAT"
    $mountKey   = "$mountRoot\$mountPrefix$username"

    Write-Host "`n===== Proxy Settings for $username =====" -ForegroundColor Cyan

    if (-not (Test-Path $ntuserPath)) {
        Write-Host "❌ NTUSER.DAT not found or inaccessible"
        continue
    }

    try {
        # Attempt to load the hive
        $loadResult = & reg load $mountKey $ntuserPath 2>&1
        if ($loadResult -like "*error*" -or $loadResult -like "*in use*") {
            Write-Host "⚠️  Cannot load hive (in use or already loaded)"
            continue
        }

        # Read proxy settings
        Get-ItemProperty -Path "Registry::$mountKey\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
            -ErrorAction Stop |
            Select-Object ProxyEnable, ProxyServer, AutoConfigURL |
            Format-List
    }
    catch {
        Write-Host "❌ Failed to read proxy settings: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        # Always attempt to unload the hive to prevent registry leaks
        & reg unload $mountKey | Out-Null
    }
}
