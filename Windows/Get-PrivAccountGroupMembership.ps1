#####################################################################
# AD Privileged Account Group Membership Report
#
# Description:
#   Discovers all members of privileged Active Directory groups,
#   queries their account details and direct group memberships,
#   exports a timestamped CSV report, and emails a plain-text
#   summary with change detection against the previous run.
#
# Features:
#   - Curated list of privileged groups plus wildcard *admin* sweep
#   - Recursive group expansion, deduplicated by SamAccountName
#   - Per-account detail: enabled state, last logon, password age,
#     locked status, and all direct group memberships
#   - Change detection vs last run: new/removed accounts and
#     group membership additions/removals
#   - Auto-versioned output files (no overwrite within same month)
#   - Auto-discovers nearest available Domain Controller
#   - Emails report with CSV attachment via unauthenticated SMTP
#
# Environment:
#   - Designed to run on a domain-joined Windows machine
#   - Requires the ActiveDirectory PowerShell module (RSAT)
#
# Usage:
#   1. Set your domain, email, SMTP, and path values in the
#      configuration block below
#   2. Add or remove groups from $CuratedGroups as needed
#   3. Run from an elevated PowerShell session:
#      powershell.exe -File Get-PrivAccountGroupMembership.ps1
#
# Prerequisites:
#   - RSAT: Active Directory Domain Services Tools installed
#   - Read access to AD (no write permissions required)
#   - Must be run from a domain-joined machine
#   - Relay-permitted SMTP server for email delivery
#
# Notes:
#   - No credentials or secrets are stored
#   - Output directory is created automatically if it does not exist
#   - Groups not found in the domain are silently skipped
#   - The first run creates a baseline; change detection starts
#     from the second run onwards
#
# Author:
#   Oskar Dlugolecki
#####################################################################

#####################################################################
# CONFIGURATION — Edit these values before running
#####################################################################

# Target AD domain to query
$Domain = "contoso.com"

# Directory to store CSV reports
$ReportDir = "C:\Reports\AD"

# Email settings
$EmailTo    = "you@example.com"
$EmailFrom  = "reports@example.com"
$SMTPServer = "smtp.example.com"
$SMTPPort   = 25

# Privileged groups to audit — add or remove as needed for your environment
$CuratedGroups = @(
    "Domain Admins",
    "Enterprise Admins",
    "Schema Admins",
    "Enterprise Key Admins",
    "Key Admins",
    "Administrators",
    "DnsAdmins",
    "Server Operators",
    "Remote Desktop Users",
    "Account Operators",
    "Hyper-V Administrators",
    "Storage Replica Administrators"
)

#####################################################################
# SCRIPT — Do not edit below this line
#####################################################################

Import-Module ActiveDirectory

$ReportDate = Get-Date -Format "yyyy-MM"
$SafeDomain = $Domain -replace "\.", "_"
$BasePath   = "$ReportDir\Priv_Account_Report_${SafeDomain}_${ReportDate}"

# --- CREATE DIRECTORY IF NEEDED ---
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir | Out-Null
    Write-Host "Created directory: $ReportDir"
}

# --- FIND LAST RUN FILE BEFORE GENERATING NEW ONE ---
$LastRunFile = Get-ChildItem -Path $ReportDir -Filter "Priv_Account_Report_${SafeDomain}_*.csv" |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1

if ($LastRunFile) {
    Write-Host "Last run file: $($LastRunFile.Name)"
} else {
    Write-Host "No previous run found - this will be the baseline."
}

# --- AUTO-DISCOVER AN AVAILABLE DC ---
try {
    $DC = (Get-ADDomainController -Discover -DomainName $Domain -NextClosestSite).HostName[0]
    Write-Host "Using DC: $DC"
} catch {
    Write-Error "Could not find an available DC for domain '$Domain': $_"
    exit 1
}

# --- VERSION OUTPUT FILE IF ONE ALREADY EXISTS THIS MONTH ---
if (Test-Path "$BasePath.csv") {
    $RunStamp   = Get-Date -Format "ddHHmm"
    $OutputPath = "${BasePath}_run${RunStamp}.csv"
} else {
    $OutputPath = "$BasePath.csv"
}

# --- STEP 1: COLLECT ALL UNIQUE PRIVILEGED ACCOUNTS ---
# Recursively expand all curated groups, deduplicate by SamAccountName,
# and also sweep any group whose name contains "admin" so nothing falls
# through the cracks.

Write-Host "Collecting privileged account list..."

$PrivAccounts = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new()

function Add-MembersFromGroup {
    param($GroupName, $DC, $SourceLabel)
    try {
        $Members = Get-ADGroupMember -Identity $GroupName -Server $DC -Recursive -ErrorAction Stop
        foreach ($m in $Members) {
            if ($m.objectClass -eq "user" -and -not $PrivAccounts.ContainsKey($m.SamAccountName)) {
                $PrivAccounts[$m.SamAccountName] = [PSCustomObject]@{
                    SamAccountName = $m.SamAccountName
                    Name           = $m.Name
                    DiscoveredVia  = $SourceLabel
                }
            }
        }
    } catch {
        Write-Warning "Could not enumerate '$GroupName': $_"
    }
}

# Curated groups first
foreach ($Group in $CuratedGroups) {
    Add-MembersFromGroup -GroupName $Group -DC $DC -SourceLabel "Curated:$Group"
}

# Wildcard *admin* sweep (skip already-curated ones)
$WildcardGroups = Get-ADGroup -Filter { Name -like "*admin*" } -Server $DC |
                  Select-Object -ExpandProperty Name | Sort-Object
foreach ($Group in $WildcardGroups) {
    if ($CuratedGroups -notcontains $Group) {
        Add-MembersFromGroup -GroupName $Group -DC $DC -SourceLabel "Wildcard:$Group"
    }
}

Write-Host "Found $($PrivAccounts.Count) unique privileged account(s)."

# --- STEP 2: FOR EACH ACCOUNT, GET ALL THEIR GROUP MEMBERSHIPS ---
# Get-ADPrincipalGroupMembership returns direct memberships only, which is
# intentional here - we want to show where the account *directly* sits,
# not re-explode the full recursive chain (that gets very noisy).
# To get recursive memberships instead, replace with:
#   $Groups = Get-ADPrincipalGroupMembership -Identity $Sam -Server $DC -ResourceContextServer $DC

Write-Host "Querying group memberships for each account..."

$Results = @()

foreach ($kvp in $PrivAccounts.GetEnumerator()) {
    $Sam    = $kvp.Key
    $AccObj = $kvp.Value

    try {
        $UserDetails = Get-ADUser -Identity $Sam -Server $DC `
                        -Properties Enabled, PasswordLastSet, LastLogonDate, `
                                    PasswordNeverExpires, LockedOut `
                        -ErrorAction Stop

        $Groups = Get-ADPrincipalGroupMembership -Identity $Sam -Server $DC -ErrorAction Stop |
                  Select-Object -ExpandProperty Name | Sort-Object

        if ($Groups.Count -eq 0) {
            $Results += [PSCustomObject]@{
                SamAccountName       = $Sam
                Name                 = $AccObj.Name
                Enabled              = $UserDetails.Enabled
                PasswordLastSet      = $UserDetails.PasswordLastSet
                LastLogonDate        = $UserDetails.LastLogonDate
                PasswordNeverExpires = $UserDetails.PasswordNeverExpires
                LockedOut            = $UserDetails.LockedOut
                GroupName            = "(no direct group memberships)"
                DiscoveredVia        = $AccObj.DiscoveredVia
            }
        } else {
            foreach ($Group in $Groups) {
                $Results += [PSCustomObject]@{
                    SamAccountName       = $Sam
                    Name                 = $AccObj.Name
                    Enabled              = $UserDetails.Enabled
                    PasswordLastSet      = $UserDetails.PasswordLastSet
                    LastLogonDate        = $UserDetails.LastLogonDate
                    PasswordNeverExpires = $UserDetails.PasswordNeverExpires
                    LockedOut            = $UserDetails.LockedOut
                    GroupName            = $Group
                    DiscoveredVia        = $AccObj.DiscoveredVia
                }
            }
        }
    } catch {
        Write-Warning "Could not process account '$Sam': $_"
        $Results += [PSCustomObject]@{
            SamAccountName       = $Sam
            Name                 = $AccObj.Name
            Enabled              = "ERROR"
            PasswordLastSet      = ""
            LastLogonDate        = ""
            PasswordNeverExpires = ""
            LockedOut            = ""
            GroupName            = "ERROR: $($_.Exception.Message)"
            DiscoveredVia        = $AccObj.DiscoveredVia
        }
    }
}

# --- EXPORT TO CSV ---
$Results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Report saved to: $OutputPath"

# --- STEP 3: BUILD PLAIN-TEXT EMAIL BODY (per-account summary) ---
$AccountBody    = ""
$SortedAccounts = $Results | Select-Object -ExpandProperty SamAccountName -Unique | Sort-Object

foreach ($Sam in $SortedAccounts) {
    $AccountRows = $Results | Where-Object { $_.SamAccountName -eq $Sam }
    $First       = $AccountRows[0]
    $LockedStr   = if ($First.LockedOut -eq $true) { " *** LOCKED ***" } else { "" }
    $PwdSet      = if ($First.PasswordLastSet) { $First.PasswordLastSet.ToString("yyyy-MM-dd") } else { "Never" }
    $LastLogon   = if ($First.LastLogonDate)   { $First.LastLogonDate.ToString("yyyy-MM-dd")   } else { "Never" }

    $AccountBody += "------------------------------------------------------------`n"
    $AccountBody += "$($First.Name) ($Sam)$LockedStr`n"
    $AccountBody += "  Enabled: $($First.Enabled)  |  Pwd Last Set: $PwdSet  |  Last Logon: $LastLogon  |  Pwd Never Expires: $($First.PasswordNeverExpires)`n"
    $AccountBody += "  Discovered via: $($First.DiscoveredVia)`n"
    $AccountBody += "  Direct group memberships ($($AccountRows.Count)):`n"
    foreach ($r in $AccountRows) {
        $AccountBody += "    - $($r.GroupName)`n"
    }
    $AccountBody += "`n"
}

# --- STEP 4: CHANGE DETECTION AGAINST LAST RUN ---
$Changes = ""

if ($LastRunFile) {
    $LastRun     = Import-Csv $LastRunFile.FullName
    $LastRunDate = $LastRunFile.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

    $LastKeys = $LastRun | Where-Object { $_.GroupName -notmatch "^(\(|ERROR)" } |
                ForEach-Object { "$($_.SamAccountName)|$($_.GroupName)" }
    $ThisKeys = $Results  | Where-Object { $_.GroupName -notmatch "^(\(|ERROR)" } |
                ForEach-Object { "$($_.SamAccountName)|$($_.GroupName)" }

    $Added   = $ThisKeys | Where-Object { $_ -notin $LastKeys }
    $Removed = $LastKeys | Where-Object { $_ -notin $ThisKeys }

    $LastSams        = $LastRun | Select-Object -ExpandProperty SamAccountName -Unique
    $ThisSams        = $Results  | Select-Object -ExpandProperty SamAccountName -Unique
    $NewAccounts     = $ThisSams | Where-Object { $_ -notin $LastSams }
    $RemovedAccounts = $LastSams | Where-Object { $_ -notin $ThisSams }

    $Changes += "============================================================`n"
    $Changes += "CHANGES SINCE LAST RUN ($LastRunDate)`n"
    $Changes += "============================================================`n"

    if ($NewAccounts) {
        $Changes += "`nNEW PRIVILEGED ACCOUNTS ($($NewAccounts.Count)):`n"
        foreach ($s in $NewAccounts) { $Changes += "  [+] $s`n" }
    } else { $Changes += "`nNEW PRIVILEGED ACCOUNTS: None`n" }

    if ($RemovedAccounts) {
        $Changes += "`nREMOVED PRIVILEGED ACCOUNTS ($($RemovedAccounts.Count)):`n"
        foreach ($s in $RemovedAccounts) { $Changes += "  [-] $s`n" }
    } else { $Changes += "`nREMOVED PRIVILEGED ACCOUNTS: None`n" }

    if ($Added) {
        $Changes += "`nGROUP MEMBERSHIPS ADDED ($($Added.Count)):`n"
        foreach ($entry in $Added) {
            $parts = $entry -split "\|"
            $Changes += "  [+] $($parts[0]) -> $($parts[1])`n"
        }
    } else { $Changes += "`nGROUP MEMBERSHIPS ADDED: None`n" }

    if ($Removed) {
        $Changes += "`nGROUP MEMBERSHIPS REMOVED ($($Removed.Count)):`n"
        foreach ($entry in $Removed) {
            $parts = $entry -split "\|"
            $Changes += "  [-] $($parts[0]) -> $($parts[1])`n"
        }
    } else { $Changes += "`nGROUP MEMBERSHIPS REMOVED: None`n" }

} else {
    $Changes = "No previous run found — this is the baseline.`n"
}

# --- SEND EMAIL ---
$Subject = "Privileged Account Group Membership Report - $Domain - $ReportDate"
$Body    = @"
Privileged account group membership report for $Domain ($ReportDate).
DC Queried : $DC
Accounts   : $($SortedAccounts.Count)
Full CSV attached.

$Changes

============================================================
CURRENT PRIVILEGED ACCOUNT MEMBERSHIPS
============================================================

$AccountBody

Regards,
Automated AD Reporting
"@

$SMTPClient           = New-Object Net.Mail.SmtpClient($SMTPServer, $SMTPPort)
$SMTPClient.EnableSsl = $false
$Message              = New-Object Net.Mail.MailMessage
$Message.From         = $EmailFrom
$Message.To.Add($EmailTo)
$Message.Subject      = $Subject
$Message.Body         = $Body
$Message.Attachments.Add($OutputPath)

$SMTPClient.Send($Message)
Write-Host "Report emailed to $EmailTo"
