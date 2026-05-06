#####################################################################
# DNS A Record Exporter
#
# Description:
#   Queries all primary zones on a Windows DNS server and exports
#   every A record (hostname + IP address) to a single CSV file.
#   Useful for auditing, documentation, and IPAM reconciliation.
#
# Features:
#   - Targets all primary DNS zones automatically
#   - Skips zone apex (@) records
#   - Outputs fully qualified hostnames in lowercase
#   - Single consolidated CSV export
#
# Environment:
#   - Designed to run on any Windows machine with RSAT DNS tools
#   - Requires the DnsServer PowerShell module
#
# Usage:
#   1. Set your DNS server and output path in the configuration block below
#   2. Run the script from an elevated PowerShell session
#   3. Find the exported CSV at the path defined in $OutputFile
#
# Prerequisites:
#   - RSAT: DNS Server Tools installed
#   - Read access to the target DNS server
#   - Network connectivity to the DNS server
#
# Notes:
#   - No credentials or secrets are stored
#   - Output directory must exist before running
#
# Author:
#   Oskar Dlugolecki
#####################################################################

#####################################################################
# CONFIGURATION — Edit these values before running
#####################################################################

# FQDN or IP address of the DNS server to query
$DnsServer = "dns01.example.com"

# Full path for the exported CSV file (directory must exist)
$OutputFile = "C:\Temp\dns-records.csv"

#####################################################################
# SCRIPT — Do not edit below this line
#####################################################################

# Initialize record list
$allRecords = @()

# Get all primary zones
$zones = Get-DnsServerZone -ComputerName $DnsServer |
         Where-Object { $_.ZoneType -eq "Primary" }

foreach ($zone in $zones) {
    # Get A records, excluding zone apex
    $records = Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -ComputerName $DnsServer |
               Where-Object { $_.RecordType -eq "A" -and $_.HostName -ne "@" }

    # Append formatted records to list
    $allRecords += $records | ForEach-Object {
        [PSCustomObject]@{
            Hostname  = ($_.HostName + "." + $zone.ZoneName).ToLower()
            IPAddress = $_.RecordData.IPv4Address.IPAddressToString
        }
    }
}

# Export all records to CSV
$allRecords | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "Exported $($allRecords.Count) records to $OutputFile"
