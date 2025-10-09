#####################################################################
# Script: Test-AVDOutboundConnectivity.ps1
#
# Description:
#   Tests outbound TCP connectivity on port 443 from a specified VM
#   to key Azure Virtual Desktop endpoints using Invoke-AzVMRunCommand.
#
# Usage:
#   - Replace <ResourceGroupName> and <VMName> with your actual resource group and VM names.
#   - Run this script in an environment with Az modules and proper permissions.
#####################################################################

Invoke-AzVMRunCommand -ResourceGroupName "<ResourceGroupName>" -Name "<VMName>" `
  -CommandId 'RunPowerShellScript' `
  -ScriptString @'
    Write-Host "Testing outbound 443 to AVD endpoints..."
    Test-NetConnection -ComputerName rdweb.wvd.microsoft.com -Port 443 | Select ComputerName, RemotePort, TcpTestSucceeded
    Test-NetConnection -ComputerName global.prod.warm.ingestion.ms -Port 443 | Select ComputerName, RemotePort, TcpTestSucceeded
    Test-NetConnection -ComputerName wvd.microsoft.com -Port 443 | Select ComputerName, RemotePort, TcpTestSucceeded
'@
