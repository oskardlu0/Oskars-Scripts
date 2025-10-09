#### ----------------------------------------------------------------------------
#### Script: Clear IPAM Nodes
#### 
#### Description:
####   Connects to a SolarWinds IPAM instance using SwisPowerShell.
####   For each IP in the provided list:
####     - Looks up the IP node in IPAM.
####     - Clears DnsBackward, SysName, DhcpClientName, and Comments fields.
####     - Sets Status to "Available" (numeric value 2).
####     - Confirms the update and outputs a summary table.
####
#### Requirements:
####   - PowerShell
####   - SwisPowerShell module installed
####
#### Configuration:
####   $hostname   - IPAM hostname (sensitive)
####   $username   - Username for IPAM (sensitive)
####   $plainPwd   - Plain text password (sensitive)
####   $IpList     - List of IP addresses to process (environment-specific)
####
#### Warning:
####   - This script modifies live IPAM data. Double-check $hostname and $IpList before running.
####   - Test in a non-production environment first.
####   - Do NOT commit $hostname, $username, or $plainPwd to GitHub.
####
#### Example Usage:
####   .\Clear-IPAMNodes.ps1
#### ----------------------------------------------------------------------------



#Requires -Modules SwisPowerShell
$hostname = 'x'
$username = 'x'
$plainPwd = 'x'

# ---- IPs to process ----
$IpList = @(
    'x'
    'x'
)

Import-Module SwisPowerShell -ErrorAction Stop
$secure = ConvertTo-SecureString $plainPwd -AsPlainText -Force
$cred   = [pscredential]::new($username, $secure)
$swis   = Connect-Swis -Hostname $hostname -Credential $cred

Write-Host "Processing $($IpList.Count) IP(s) against $hostname ...`n"

$results = foreach ($ip in $IpList) {
    try {
        # Lookup node
        $row = Get-SwisData $swis @"
SELECT Uri, IPAddress, Status, DnsBackward, SysName, DhcpClientName, Comments
FROM IPAM.IPNode
WHERE IPAddress=@ip
"@ @{ ip = $ip }

        if (-not $row) {
            Write-Warning ("{0} : No IPAM.IPNode found" -f $ip)
            continue
        }

        $uri = $row[0].Uri

        # Clear all names + comments + set status to Available
        Set-SwisObject -SwisConnection $swis -Uri $uri -Properties @{
            DnsBackward    = $null
            SysName        = $null
            DhcpClientName = $null
            Comments       = $null
            Status         = 2
        } | Out-Null

        # Confirm changes
        $after = Get-SwisData $swis @"
SELECT IPAddress, Status, DnsBackward, SysName, DhcpClientName, Comments
FROM IPAM.IPNode
WHERE Uri=@u
"@ @{ u = $uri }

        Write-Host ("{0} : Updated" -f $ip)

        [pscustomobject]@{
            IP             = $ip
            Status         = $after[0].Status
            DnsBackward    = $after[0].DnsBackward
            SysName        = $after[0].SysName
            DhcpClientName = $after[0].DhcpClientName
            Comments       = $after[0].Comments
        }
    }
    catch {
        Write-Warning ("{0} : ERROR - {1}" -f $ip, $_.Exception.Message)
    }
}

# Summary
$results | Sort-Object IP | Format-Table -AutoSize
