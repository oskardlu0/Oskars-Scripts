#####################################################################
# Azure Virtual Desktop (AVD) Session Hosts Assigned User Report
#
# Description:
#   This script lists all session hosts in an AVD host pool along with
#   their currently assigned users. Useful for auditing and management
#   of AVD session host assignments.
#
# Usage:
#   Run this script in Azure Cloud Shell or any PowerShell environment
#   with the Az module installed and authenticated.
#
# Configuration:
#   - Set $SubscriptionId to your Azure subscription ID.
#   - Set $ResourceGroup to your resource group containing the host pool.
#   - Set $HostPoolName to the name of your AVD host pool.
#
# Output:
#   Displays a table of session host names and their assigned user UPNs.
#####################################################################

$SubscriptionId = ''  # Your Azure subscription ID here
$ResourceGroup  = ''  # Your resource group name here
$HostPoolName   = ''  # Your AVD host pool name here

Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

# REST API version to use for the request
$apiVersion = '2024-04-03'

# Construct the REST API path to get session hosts
$path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=$apiVersion"

# Invoke REST API to get session hosts
$response = Invoke-AzRest -Method GET -Path $path
$hosts    = ($response.Content | ConvertFrom-Json).value

# Output header
Write-Host "SessionHost`tAssignedUser"
Write-Host "-----------`t-------------"

# Loop through each host and display the assigned user
foreach ($h in $hosts) {
    $shortName = $h.name.Split('/')[-1]
    if ($h.properties.assignedUser -is [string]) {
        $upn = $h.properties.assignedUser
    } elseif ($h.properties.assignedUser -and $h.properties.assignedUser.userPrincipalName) {
        $upn = $h.properties.assignedUser.userPrincipalName
    } else {
        $upn = '<none>'
    }
    Write-Host ("{0,-20}`t{1}" -f $shortName, $upn)
}
