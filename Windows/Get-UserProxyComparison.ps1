#####################################################################
# Compare Proxy Settings Between Current and Target User
#
# Filename:    Get-UserProxyComparison.ps1
# Usage:       powershell.exe -File Get-UserProxyComparison.ps1
#
# Description:
#   Reads and compares Internet Explorer/WinInet proxy settings for
#   the currently logged-on user and a specified target user account.
#   The target user does not need to be logged on — their settings
#   are read by temporarily mounting their NTUSER.DAT registry hive.
#
# Features:
#   - Reads live proxy settings from the current user's registry
#   - Mounts a target user's NTUSER.DAT without requiring a logon
#   - Displays ProxyEnable, ProxyServer, and AutoConfigURL for both
#   - Safely unmounts the hive after reading
#   - Gracefully handles missing profiles or unreadable hives
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
#
# Notes:
#   - No credentials or secrets are stored
#   - The temporary registry mount is always unloaded after reading
#   - Settings reflect WinInet/IE proxy config, which is also used
#     by many applications that do not manage their own proxy
#
# Author:
#   Oskar Dlugolecki
#####################################################################

#####################################################################
# CONFIGURATION — Edit these values before running
#####################################################################

# Username of the target account to compare against (local or domain)
$targetUser = "username"

#####################################################################
# SCRIPT — Do not edit below this line
#####################################################################

$targetUserProfile = "C:\Users\$targetUser"
$ntUserDatPath     = "$targetUserProfile\NTUSER.DAT"
$mountKey          = "HKU\TempProxyCompare"

# --- CURRENT USER PROXY SETTINGS ---
Write-Host "`n===== Current User Proxy Settings =====" -ForegroundColor Cyan
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
    Select-Object ProxyEnable, ProxyServer, AutoConfigURL

# --- TARGET USER PROXY SETTINGS ---
if (Test-Path $ntUserDatPath) {
    try {
        # Load target user's registry hive under a temporary key
        reg load "$mountKey" "$ntUserDatPath" | Out-Null

        Write-Host "`n===== $targetUser Proxy Settings =====" -ForegroundColor Yellow
        Get-ItemProperty -Path
