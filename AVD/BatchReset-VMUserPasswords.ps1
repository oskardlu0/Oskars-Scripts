#########################################################################
# Azure VM Local User Password Reset Script - Cloud Shell Edition
#
# Description:
#   This PowerShell script automates the process of resetting the password
#   for a specified local user on multiple Azure VMs within a resource group.
#   It ensures that each VM is powered on and fully provisioned before
#   attempting the password reset.
#
# Usage:
#   - Configure the subscription ID, resource group, local username, new password,
#     and list of target VMs in the Configuration section below.
#   - Run the script in Azure Cloud Shell.
#
# Notes:
#   - Requires Azure CLI to be installed and authenticated.
#   - Resets password using the `net user` command executed via Azure VM Run Command.
#########################################################################

# === Configuration ===
$subscriptionId = ""
$resourceGroup  = ""
$localUser      = "azureadmin"
$newPassword    = ''

# List all your target VM names here (without any suffixes)
$vmList = @(
  "avd-64","avd-67",
  "avd-68","avd-75","avd-78","avd-79","avd-81",
  "avd-90"
)

Write-Host "`n=== Setting subscription to $subscriptionId ===" -ForegroundColor Cyan
az account set --subscription $subscriptionId

foreach ($vmName in $vmList) {
    Write-Host "`n--- Processing VM: $vmName ---" -ForegroundColor Yellow

    # 1) Get current power state
    $powerState = az vm get-instance-view `
      --resource-group $resourceGroup `
      --name $vmName `
      --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" `
      -o tsv 2>$null

    if (-not $powerState) {
        Write-Host "❌ Could not retrieve state for $vmName. Skipping." -ForegroundColor Red
        continue
    }

    # 2) If it's not running, start and wait for running
    if ($powerState -ne "VM running") {
        Write-Host "VM is '$powerState'. Starting $vmName..." -ForegroundColor DarkYellow
        az vm start --resource-group $resourceGroup --name $vmName | Out-Null

        Write-Host " Waiting for PowerState/running…" -NoNewline
        az vm wait `
          --resource-group $resourceGroup `
          --name $vmName `
          --custom "instanceView.statuses[?code=='PowerState/running']" `
          --interval 10 --timeout 600
        Write-Host " ✅"
    }
    else {
        Write-Host "✅ $vmName is already running." -ForegroundColor Green
    }

    # 3) Wait for provisioning to finish
    Write-Host " Waiting for ProvisioningState/succeeded…" -NoNewline
    az vm wait `
      --resource-group $resourceGroup `
      --name $vmName `
      --custom "instanceView.statuses[?code=='ProvisioningState/succeeded']" `
      --interval 10 --timeout 600
    Write-Host " ✅"

    # 4) Reset the local user password via in-guest net user
    Write-Host "Resetting password on $vmName…" -NoNewline
    az vm run-command invoke `
      --resource-group $resourceGroup `
      --name $vmName `
      --command-id RunPowerShellScript `
      --scripts "net user $localUser $newPassword" `
      --only-show-errors -o none

    if ($LASTEXITCODE -eq 0) {
        Write-Host " ✅ Password reset succeeded." -ForegroundColor Green
    }
    else {
        Write-Host " ❌ Password reset FAILED on $vmName!" -ForegroundColor Red
    }
}
