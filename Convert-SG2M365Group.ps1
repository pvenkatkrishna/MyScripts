<#
.SYNOPSIS
    Converts an Azure AD Security Group to a Mail-Enabled Security Group (MESG) or Unified Group (M365 Group).

.DESCRIPTION
    This script identifies a security-enabled Azure AD group and allows you to convert it either to a Mail-Enabled Security Group or a Microsoft 365 Group.
    If a target group with the same mailNickname exists, it offers to sync members to the existing group.
    Handles duplicate display names, supports dry-run mode, and generates a CSV report of changes.

.NOTES
    Author: Krishna Pichara
    Version: 1.5
    Date: 2025-06-19
    Requirements: Microsoft.Graph PowerShell SDK installed and authenticated with sufficient privileges.

.PARAMETER dryRun
    If $true, the script simulates the actions without applying changes.

.EXAMPLE
    PS> .\Convert-SG2M365Group.ps1

.VERSIONHISTORY
    1.0 - Initial release
    1.1 - Added duplicate group detection and selection
    1.2 - Added dry-run mode
    1.3 - Added member sync and reporting
    1.4 - Improved mailNickname generation and validation
    1.5 - Enhanced error handling and reporting, updated documentation
#>

# PARAMETERS & INITIALIZATION
$dryRun = $false  # Change to $true to simulate actions
$report = @()
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# CONNECT TO GRAPH
$sgName = Read-Host "`nEnter the Security Group name to convert"
Connect-MgGraph -Scopes "Group.ReadWrite.All", "User.Read.All", "Directory.ReadWrite.All" -NoWelcome

# LOOKUP GROUPS
$sgList = Get-MgGroup -Filter "displayName eq '$sgName'" -Property "id,displayName,groupTypes,mail,mailNickname,securityEnabled,mailEnabled" -ConsistencyLevel eventual
if (-not $sgList) { Write-Host "Group not found." -ForegroundColor Red; exit 1 }

if ($sgList.Count -gt 1) {
    Write-Host "`nMultiple groups found with the name '$sgName'." -ForegroundColor Yellow
    Write-Host "`nThis may happen if the group you're trying to convert already has a mail-enabled or Microsoft 365 version."
    Write-Host "==> In such cases, consider which group is your *source* Security Group (usually MailEnabled: False, GroupTypes: empty)."
    Write-Host "You'll be syncing members *from* this source group into an existing or new target group.\n"

    for ($i = 0; $i -lt $sgList.Count; $i++) {
        $g = $sgList[$i]
        $marker = if (-not $g.MailEnabled -and !$g.GroupTypes) { "✅ Likely Source" } else { "" }
        Write-Host "[$($i+1)] DisplayName : $($g.DisplayName) $marker"
        Write-Host "     Id           : $($g.Id)"
        Write-Host "     MailEnabled  : $($g.MailEnabled)"
        Write-Host "     MailNickname : $($g.MailNickname)"
        Write-Host "     GroupTypes   : $($g.GroupTypes -join ', ')"
        Write-Host ""
    }
    $choice = Read-Host "Select the group number (1-$($sgList.Count)) that represents the original source Security Group to convert"
    if (-not ($choice -as [int]) -or $choice -lt 1 -or $choice -gt $sgList.Count) {
        Write-Host "Invalid selection." -ForegroundColor Red; exit 1
    }
    $sg = $sgList[$choice - 1]
    Write-Host "You selected group: $($sg.DisplayName) [ID: $($sg.Id)]" -ForegroundColor Cyan
} else {
    $sg = $sgList | Select-Object -First 1
}

# GENERATE MAILNICKNAME
$displayName = $sg.DisplayName
$mailNickname = ($displayName -replace '[^a-zA-Z0-9]', '.').Trim('.') -replace '\.{2,}', '.'
if ($mailNickname -match '^[^a-zA-Z]') { $mailNickname = "grp.$mailNickname" }
if ($mailNickname.Length -gt 64) { $mailNickname = $mailNickname.Substring(0,64) }

# CHOOSE TARGET TYPE
$targetType = Read-Host "Convert to: 1) Mail-Enabled Security Group  2) Microsoft 365 Group (Unified). Enter 1 or 2"
if ($targetType -notin @('1','2')) { Write-Host "Invalid selection." -ForegroundColor Red; exit 1 }

# DETERMINE EXISTING GROUPS BASED ON TYPE
$filter = "mailNickname eq '$mailNickname' and mailEnabled eq true"
$filter += if ($targetType -eq '1') { " and securityEnabled eq true" } else { " and securityEnabled eq false" }
$conflict = Get-MgGroup -Filter $filter -Property "id,displayName,mail,mailNickname,groupTypes" -ConsistencyLevel eventual

if ($conflict) {
    Write-Host "`nConflict detected. Details of the existing group:" -ForegroundColor Yellow
    $conflict | ForEach-Object {
        Write-Host "DisplayName : $($_.DisplayName)"
        Write-Host "Group ID    : $($_.Id)"
        Write-Host "Mail        : $($_.Mail)"
        Write-Host "MailNickname: $($_.MailNickname)"
        Write-Host "GroupTypes  : $($_.GroupTypes -join ', ')"
        Write-Host ""
    }

    $sourceMembers = Get-MgGroupMember -GroupId $sg.Id -All
    $targetMembers = Get-MgGroupMember -GroupId $conflict.Id -All

    $sourceMemberIds = $sourceMembers.Id
    $targetMemberIds = $targetMembers.Id
    $membersOnlyInSource = $sourceMemberIds | Where-Object { $_ -notin $targetMemberIds }
    $membersOnlyInTarget = $targetMemberIds | Where-Object { $_ -notin $sourceMemberIds }

    Write-Host "`n=== Member Comparison ===" -ForegroundColor Cyan
    Write-Host "Source Group Members       : $($sourceMemberIds.Count)"
    Write-Host "Target Group Members       : $($targetMemberIds.Count)"
    Write-Host "Members only in Source     : $($membersOnlyInSource.Count)"
    Write-Host "Members only in Target     : $($membersOnlyInTarget.Count)"

    if ((Read-Host "Do you want to sync members to the existing group? (Y/N)") -eq 'Y') {
        foreach ($member in $sourceMembers) {
            if ($targetMembers.Id -notcontains $member.Id) {
                if ($dryRun) {
                    Write-Host "[DryRun] Would add member: $($member.Id)"
                } else {
                    try {
                        New-MgGroupMember -GroupId $conflict.Id -DirectoryObjectId $member.Id
                    } catch {
                        Write-Host "Failed to add member $($member.Id): $_" -ForegroundColor Red
                    }
                }
                $report += [pscustomobject]@{Action="AddMember"; TargetGroup=$conflict.DisplayName; ObjectId=$member.Id}
            }
        }
        if (-not $dryRun) {
            $newMembers = Get-MgGroupMember -GroupId $conflict.Id -All
            Write-Host "After sync: Target group has $($newMembers.Count) members." -ForegroundColor Green
        }
        Write-Host "Sync complete." -ForegroundColor Green
        $report | Export-Csv "SyncReport_$($conflict.Id)_$timestamp.csv" -NoTypeInformation
        Write-Host "Report exported to: SyncReport_$($conflict.Id)_$timestamp.csv" -ForegroundColor Cyan
        exit
    } else {
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        exit 1
    }
}

# CREATE NEW GROUP
Write-Host "Creating new group..."
if ($dryRun) {
    Write-Host "[DryRun] Would create new group: $displayName with MailNickname: $mailNickname"
} else {
    try {
        if ($targetType -eq '1') {
            $newGroup = New-MgGroup -DisplayName $displayName -MailNickname $mailNickname -MailEnabled:$true -SecurityEnabled:$true -GroupTypes @() -Visibility "Private"
        } else {
            $newGroup = New-MgGroup -DisplayName $displayName -MailNickname $mailNickname -MailEnabled:$true -SecurityEnabled:$false -GroupTypes @("Unified") -Visibility "Private"
        }

        if ($newGroup) {
            Write-Host "New group created: $displayName" -ForegroundColor Green

            $members = Get-MgGroupMember -GroupId $sg.Id -All
            Write-Host "Found $($members.Count) members in source group."
            $syncConfirm = Read-Host "Do you want to sync these members to the new group? (Y/N)"
            if ($syncConfirm -ne 'Y') {
                Write-Host "Member sync cancelled by user." -ForegroundColor Yellow
                exit 0
            }

            foreach ($member in $members) {
                try {
                    New-MgGroupMember -GroupId $newGroup.Id -DirectoryObjectId $member.Id
                } catch {
                    Write-Host "Failed to add member $($member.Id): $_" -ForegroundColor Red
                }
                $report += [pscustomobject]@{Action="AddMember"; TargetGroup=$newGroup.DisplayName; ObjectId=$member.Id}
            }

            $report | Export-Csv "ConversionReport_$($newGroup.Id)_$timestamp.csv" -NoTypeInformation
            Write-Host "Report exported to: ConversionReport_$($newGroup.Id)_$timestamp.csv" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "Failed to create group: $_" -ForegroundColor Red
    }
}
