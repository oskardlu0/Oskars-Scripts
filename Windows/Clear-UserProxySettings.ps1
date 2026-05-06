#####################################################################
# Clear Proxy Settings for Offline User Profile
#
# Filename:    Clear-UserProxySettings.ps1
# Usage:       powershell.exe -File Clear-UserProxySettings.ps1
#
# Description:
#   Disables and removes WinInet proxy settings from a target user's
#   registry hive without requiring them to be logged on. Mounts the
#   user's NTUSER.DAT temporarily, clears ProxyEnable, ProxyServer,
#   and AutoConfigURL, then safely unmounts the hive.
#
# Features:
#   - Targets an offline user profile via NTUSER.DAT hive mounting
#   - Disables proxy (ProxyEnable = 0)
#   - Removes ProxyServer and AutoConfigURL values if present
#   - Always unloads the hive in a finally block to prevent leaks
#   - Gracefully handles missing profiles or inaccessible hives
#
# Environment:
#   - Designed to run on any Windows machine
#   - No additional modules required
#
# Usage:
#   1. Set the target username in $targetUser below
#   2. Run from an elevated PowerShell session (required to mount
#      registry hives with reg load)
#
# Prerequisites:
#   - Must be run as Administrator
#   - Target user must have a local profile on this machine
#   - Target user must not be currently logged on (hive must be free)
#
# Notes:
#   - No credentials or secrets are stored
#   - This modifies the user's registry — changes take effect on
#     their next logon
#   - If the user is currently logged on their hive will be locked
#     and the script will fail to load it
#
# Author:
#   Oskar Dlugolecki
#####################################################################

#####################################################################
# CONFIGURATION — Edit these values before running
#####################################################################

# Username of the target account to clear proxy settings for
$targetUser = "username"

#####################################################################
# SCRIPT — Do not edit below this line
#####################################################################

$profilePath = "C:\Users\$targetUser"
$ntuserPath  = "$profilePath\NTUSER.DAT"
$mountKey    = "HKU\TempProxyEdit"

if (-not (Test-Path $ntuserPath)) {
    Write-Host "❌ NTUSER.DAT not found for $targetUser" -ForegroundColor Red
    return
}

try {
    Write-Host "🔧 Loading registry hive for $targetUser ..."
    & reg load $mountKey $ntuserPath | Out-Null

    $regPath = "Registry::$mountKey\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

    Write-Host "🚫 Disabling proxy settings ..."
    Set-ItemProperty    -Path $regPath -Name ProxyEnable   -Value 0 -ErrorAction Stop
    Remove-ItemProperty -Path $regPath -Name ProxyServer   -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue

    Write-Host "✅ Proxy settings cleared successfully for $targetUser" -ForegroundColor Green
}
catch {
    Write-Host "❌ Failed to modify proxy settings: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host "🔄 Unloading hive ..."
    & reg unload $mountKey | Out-Null
}
