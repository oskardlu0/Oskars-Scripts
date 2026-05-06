#####################################################################
# Monthly AD Group Membership Report
#
# Filename:    Get-ADGroupMembershipReport.ps1
# Usage:       powershell.exe -File Get-ADGroupMembershipReport.ps1
#
# Description:
#   Queries membership of curated privileged AD groups plus a
#   wildcard *admin* sweep, exports a timestamped CSV, and emails
#   a plain-text summary with change detection against the previous
#   run. Separated into two sections: curated groups and wildcard
#   groups, each with their own change tracking.
#
# Features:
#   - Curated list of privileged groups plus wildcard *admin* sweep
#   - Recursive group expansion with enabled/disabled status per user
#   - Separate change detection for curated vs wildcard groups
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
#      powershell.exe -File Get-ADGroupMembershipReport.ps1
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
$BasePath   = "$ReportDir\AD_Group_Report_${SafeDomain}_${ReportDate}"

# --- CREATE DIRECTORY IF NEEDED ---
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir | Out-Null
    Write-Host "Created directory: $ReportDir"
}

# --- FIND LAST RUN FILE BEFORE GENERATING NEW ONE ---
$LastRunFile = Get-ChildItem -Path $ReportDir -Filter "AD_Group_Report_${SafeDomain}_*.csv" |
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

# --- FUNCTION TO QUERY GROUP MEMBERS ---
function Get-GroupMembers {
    param($GroupName, $DC, $Domain)

    $rows = @()
    try {
        $Members = Get-ADGroupMember -Identity $GroupName -Server $DC -Recursive -ErrorAction Stop

        if ($Members.Count -eq 0) {
            $rows += [PSCustomObject]@{
                Section    = ""
                Domain     = $Domain
                Group      = $GroupName
                MemberName = "(empty)"
                SamAccount = ""
                ObjectType = ""
                Enabled    = ""
            }
        } else {
            foreach ($Member in $Members) {
                $Enabled = ""
                if ($Member.objectClass -eq "user") {
                    try {
                        $User    = Get-ADUser -Identity $Member.SamAccountName -Server $DC -Properties Enabled -ErrorAction Stop
                        $Enabled = $User.Enabled
                    } catch { $Enabled = "Unknown" }
                }
                $rows += [PSCustomObject]@{
                    Section    = ""
                    Domain     = $Domain
                    Group      = $GroupName
                    MemberName = $Member.Name
                    SamAccount = $Member.SamAccountName
                    ObjectType = $Member.objectClass
                    Enabled    = $Enabled
                }
            }
        }
    } catch {
        Write-Warning "Could not query '$GroupName' on '$DC': $_"
        $rows += [PSCustomObject]@{
            Section    = ""
            Domain     = $Domain
            Group      = $GroupName
            MemberName = "ERROR: $($_.Exception.Message)"
            SamAccount = ""
            ObjectType = ""
            Enabled    = ""
        }
    }
    return $rows
}

# --- COLLECT CURATED GROUP DATA ---
Write-Host "Processing curated groups..."
$CuratedResults = @()
foreach ($Group in $CuratedGroups) {
    $rows = Get-GroupMembers -GroupName $Group -DC $DC -Domain $Domain
    foreach ($r in $rows) { $r.Section = "Curated" }
    $CuratedResults += $rows
}

# --- COLLECT WILDCARD ADMIN GROUP DATA ---
Write-Host "Processing wildcard admin groups..."
$WildcardGroups  = Get-ADGroup -Filter { Name -like "*admin*" } -Server $DC | Select-Object -ExpandProperty Name | Sort-Object
$WildcardResults = @()
foreach ($Group in $WildcardGroups) {
    if ($CuratedGroups -contains $Group) { continue }
    $rows = Get-GroupMembers -GroupName $Group -DC $DC -Domain $Domain
    foreach ($r in $rows) { $r.Section = "Wildcard" }
    $WildcardResults += $rows
}

# --- EXPORT EVERYTHING TO CSV ---
$AllResults = $CuratedResults + $WildcardResults
$AllResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Report saved to: $OutputPath"

# --- BUILD CURATED MEMBERSHIP SECTION FOR EMAIL ---
$MembershipBody = ""
foreach ($Group in $CuratedGroups) {
    $GroupMembers    = $CuratedResults | Where-Object { $_.Group -eq $Group }
    $MembershipBody += "------------------------------------------------------------`n"
    $MembershipBody += "$Group ($($GroupMembers.Count) member(s))`n"
    $MembershipBody += "------------------------------------------------------------`n"
    if ($GroupMembers.Count -eq 0 -or ($GroupMembers.Count -eq 1 -and $GroupMembers[0].MemberName -eq "(empty)")) {
        $MembershipBody += "  (empty)`n"
    } else {
        foreach ($m in $GroupMembers) {
            $EnabledStr      = if ($m.Enabled -ne "") { " [Enabled: $($m.Enabled)]" } else { "" }
            $MembershipBody += "  $($m.MemberName) ($($m.SamAccount)) [$($m.ObjectType)]$EnabledStr`n"
        }
    }
    $MembershipBody += "`n"
}

# --- COMPARE AGAINST LAST RUN ---
$CuratedChanges  = ""
$WildcardChanges = ""

if ($LastRunFile) {
    $LastRun     = Import-Csv $LastRunFile.FullName
    $LastRunDate = $LastRunFile.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

    # Curated changes
    $LastCuratedKeys = $LastRun | Where-Object { $_.Section -eq "Curated" -and $_.SamAccount -ne "" } | ForEach-Object { "$($_.Group)|$($_.SamAccount)" }
    $ThisCuratedKeys = $CuratedResults | Where-Object { $_.SamAccount -ne "" } | ForEach-Object { "$($_.Group)|$($_.SamAccount)" }
    $CuratedAdded    = $ThisCuratedKeys | Where-Object { $_ -notin $LastCuratedKeys }
    $CuratedRemoved  = $LastCuratedKeys | Where-Object { $_ -notin $ThisCuratedKeys }

    $CuratedChanges += "============================================================`n"
    $CuratedChanges += "CHANGES SINCE LAST RUN ($LastRunDate)`n"
    $CuratedChanges += "============================================================`n"

    if ($CuratedAdded) {
        $CuratedChanges += "`nADDED ($($CuratedAdded.Count)):`n"
        foreach ($entry in $CuratedAdded) {
            $parts           = $entry -split "\|"
            $CuratedChanges += "  [+] $($parts[1]) -> $($parts[0])`n"
        }
    } else { $CuratedChanges += "`nADDED: None`n" }

    if ($CuratedRemoved) {
        $CuratedChanges += "`nREMOVED ($($CuratedRemoved.Count)):`n"
        foreach ($entry in $CuratedRemoved) {
            $parts           = $entry -split "\|"
            $CuratedChanges += "  [-] $($parts[1]) -> $($parts[0])`n"
        }
    } else { $CuratedChanges += "`nREMOVED: None`n" }

    # Wildcard changes
    $LastWildcardKeys = $LastRun | Where-Object { $_.Section -eq "Wildcard" -and $_.SamAccount -ne "" } | ForEach-Object { "$($_.Group)|$($_.SamAccount)" }
    $ThisWildcardKeys = $WildcardResults | Where-Object { $_.SamAccount -ne "" } | ForEach-Object { "$($_.Group)|$($_.SamAccount)" }
    $WildcardAdded    = $ThisWildcardKeys | Where-Object { $_ -notin $LastWildcardKeys }
    $WildcardRemoved  = $LastWildcardKeys | Where-Object { $_ -notin $ThisWildcardKeys }

    $WildcardChanges += "============================================================`n"
    $WildcardChanges += "ALL ADMIN GROUPS (*admin*) - CHANGES SINCE LAST RUN ($LastRunDate)`n"
    $WildcardChanges += "============================================================`n"

    if ($WildcardAdded) {
        $WildcardChanges += "`nADDED ($($WildcardAdded.Count)):`n"
        foreach ($entry in $WildcardAdded) {
            $parts            = $entry -split "\|"
            $WildcardChanges += "  [+] $($parts[1]) -> $($parts[0])`n"
        }
    } else { $WildcardChanges += "`nADDED: None`n" }

    if ($WildcardRemoved) {
        $WildcardChanges += "`nREMOVED ($($WildcardRemoved.Count)):`n"
        foreach ($entry in $WildcardRemoved) {
            $parts            = $entry -split "\|"
            $WildcardChanges += "  [-] $($parts[1]) -> $($parts[0])`n"
        }
    } else { $WildcardChanges += "`nREMOVED: None`n" }

} else {
    $CuratedChanges  = "No previous run found — this is the baseline.`n"
    $WildcardChanges = "No previous run found — this is the baseline.`n"
}

# --- SEND EMAIL ---
$Subject = "Monthly AD Group Report - $Domain - $ReportDate"
$Body    = @"
Monthly AD privileged group membership report for $Domain ($ReportDate).
DC Queried: $DC
Full CSV attached.

$CuratedChanges

============================================================
CURRENT MEMBERSHIP
============================================================

$MembershipBody

$WildcardChanges

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
