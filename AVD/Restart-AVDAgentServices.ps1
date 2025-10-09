#####################################################################
# Script: Restart-AVDAgentServices.ps1
#
# Description:
#   Restarts the Azure Virtual Desktop agent services (RDAgentBootLoader and RdInfraAgent)
#   on a specified VM using Invoke-AzVMRunCommand.
#
# Usage:
#   - Replace <ResourceGroupName> and <VMName> with your actual resource group and VM names.
#   - Run this script in an environment with Az modules and proper permissions.
#####################################################################

Invoke-AzVMRunCommand -ResourceGroupName "<ResourceGroupName>" -Name "<VMName>" `
  -CommandId 'RunPowerShellScript' `
  -ScriptString @'
    Write-Host "Restarting AVD agent services..."
    Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue | ForEach-Object { Restart-Service $_.Name -Force }
    Get-Service RdInfraAgent -ErrorAction SilentlyContinue | ForEach-Object { Restart-Service $_.Name -Force }
    Start-Sleep -Seconds 10
    Get-Service RDAgentBootLoader, RdInfraAgent -ErrorAction SilentlyContinue | Select Name, Status
'@
