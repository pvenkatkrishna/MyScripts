<#
.SYNOPSIS
    Activates eligible Microsoft Entra ID roles via PIM with self-approval. Displays remaining time or permanence for currently active roles.

.DESCRIPTION
    - Connects to Microsoft Graph and fetches the signed-in user's eligible PIM roles.
    - Displays currently active roles, indicating expiration time or permanent status.
    - Presents a menu to activate any eligible role.
    - Requires justification and self-activates the role for 4 hours.
    - Supports multiple activations within a single session.
    - Allows the user to exit gracefully at any time.

.NOTES
    - Supports only **SelfActivate** scenario (no approval workflow).
    - Activation duration is set to **4 hours** by default (customizable).
    - Requires Microsoft Graph PowerShell module.
    - Must have `RoleManagement.ReadWrite.Directory` permission.

.AUTHOR
    Krishna Pichara

.VERSION
    1.0 - Base script - 13th March 2025
    1.1 - Added error handling for role activation - 4th Apr 2025
    1.2 - Added support for multiple role activations in a single session - 6th Apr 2025
    1.3 - Added option to exit the script at any point - 8th Apr 2025
    1.4 - Added validation for user input and role selection - 10th Apr 2025
    1.5 - Added comments and improved readability - 12th Apr 2025
    1.6 - Added code to display currently active roles post role activation - 15th Jun 2025
    1.7 - Enhanced active role display with expiration or permanence info - 30th Jun 2025
    1.8 - Improved permanent role detection logic - 30th Jun 2025
#>

# Ensure connection to Microsoft Graph
# This command connects to Microsoft Graph with the necessary scope.
# The '-NoWelcome' flag suppresses the welcome message.
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory" -NoWelcome

# Retrieve the currently signed-in user's UPN and ID
# Get the User Principal Name (UPN) from the current Microsoft Graph context.
$CurrentUserUPN = (Get-MgContext).Account
# Retrieve the full user object based on the UPN.
$CurrentUser = Get-MgUser -UserId $CurrentUserUPN

# Define Variables
# Get the Tenant ID from the organization information.
$TenantID = (Get-MgOrganization).Id

# Get Eligible Roles for the User
# Retrieve all eligible role schedules for the current user.
$EligibleRoles = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '$($CurrentUser.Id)'"

# Debugging: Display eligible roles (uncomment for debugging purposes)
#Write-Host "Debug: Retrieved Eligible Roles" -ForegroundColor Cyan
#$EligibleRoles | ForEach-Object { Write-Host "RoleDefinitionId: $($_.RoleDefinitionId)" }

# Check if eligible roles exist
if (-not $EligibleRoles -or $EligibleRoles.Count -eq 0) {
    Write-Host "No eligible roles found for your account." -ForegroundColor Red
    exit
}

# Retrieve role definitions only for eligible roles
# Initialize an empty array to store role definitions.
$RoleDefinitions = @()
# Loop through each eligible role to get its detailed definition.
foreach ($role in $EligibleRoles) {
    # Get the role definition by its ID.
    $RoleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -Filter "id eq '$($role.RoleDefinitionId)'"
    if ($RoleDefinition) {
        # Add the role definition to the array if found.
        $RoleDefinitions += $RoleDefinition
    }
}

# Main script loop for multiple activations
while ($true) {
    # Get currently active roles for the user
    # Retrieve all active role assignment schedules for the current user.
    $ActiveRoles = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '$($CurrentUser.Id)'"

    # Display currently active roles with refined logic
    if ($ActiveRoles.Count -gt 0) {
        Write-Host "`nCurrently Active Roles:" -ForegroundColor Green
        foreach ($activeRole in $ActiveRoles) {
            $activeRoleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "id eq '$($activeRole.RoleDefinitionId)'"
            $endTime = $null
            $isPermanent = $false

            $expiration = $activeRole.ScheduleInfo.Expiration

            if ($activeRole.AssignmentType -eq "Assigned" -and $expiration.Type -eq "noExpiration") {
                $isPermanent = $true
            } elseif ($expiration.Type -eq "afterDateTime" -and $expiration.EndDateTime) {
                $endTime = $expiration.EndDateTime
            }

            if ($activeRoleDef) {
                if ($isPermanent) {
                    Write-Host "✔ $($activeRoleDef.DisplayName) - Permanent" -ForegroundColor Yellow
                } elseif ($endTime) {
                    $timeLeft = ([datetime]$endTime.ToLocalTime()) - (Get-Date)
                    Write-Host "✔ $($activeRoleDef.DisplayName) - Expires at $($endTime.ToLocalTime()) (in $([math]::Round($timeLeft.TotalMinutes)) minutes)" -ForegroundColor Yellow
                } else {
                    Write-Host "✔ $($activeRoleDef.DisplayName) - Expiry unknown" -ForegroundColor Yellow
                }
            }
        }
    } else {
        Write-Host "`nYou currently have no active roles." -ForegroundColor DarkGray
    }

    # Display available roles for activation
    Write-Host "`nSelect a role to activate:" -ForegroundColor Cyan

    Write-Host "0. Exit script"
    # Create a hash table to map selection numbers to role IDs.
    $RoleOptions = @{}
    $Counter = 1
    # Populate the menu with eligible roles.
    $RoleDefinitions | ForEach-Object {
        Write-Host "$Counter. $($_.DisplayName)"
        $RoleOptions[$Counter] = $_.Id
        $Counter++
    }

    # Ensure at least one role is displayed (excluding the exit option)
    if ($Counter -eq 1) {
        Write-Host "No valid roles found to activate." -ForegroundColor Red
        exit
    }

    # Get user selection
    $Selection = Read-Host "Enter the number of the role to activate (or 0 to exit)"
    if ($Selection -eq "0") {
        Write-Host "Exiting script." -ForegroundColor Green
        exit
    }
    
    # Validate user selection
    while (-not $RoleOptions[[int]$Selection]) {
        Write-Host "Invalid selection. Please try again." -ForegroundColor Red
        $Selection = Read-Host "Enter the number of the role to activate (or 0 to exit)"
        if ($Selection -eq "0") {
            Write-Host "Exiting script." -ForegroundColor Green
            exit
        }
    }

    # Get selected role details
    $RoleDefinitionId = $RoleOptions[[int]$Selection]
    $RoleDefinition = $RoleDefinitions | Where-Object { $_.Id -eq $RoleDefinitionId }

    # Check if the selected role is already active
    $ActiveRoles = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '$($CurrentUser.Id)' and roleDefinitionId eq '$RoleDefinitionId'"
    if ($ActiveRoles) {
        Write-Host "$($RoleDefinition.DisplayName) role is already active. No action needed." -ForegroundColor Yellow
        continue # Continue to the next iteration of the loop
    }

    # Get Justification from User
    $Justification = ""
    while ([string]::IsNullOrWhiteSpace($Justification)) {
        $Justification = Read-Host "Enter justification for activating $($RoleDefinition.DisplayName) role"
        if ([string]::IsNullOrWhiteSpace($Justification)) {
            Write-Host "Justification is required to proceed." -ForegroundColor Red
        }
    }

    # Activate the Role in PIM
    # Get the current UTC time for the activation start.
    $StartTime = (Get-Date).ToUniversalTime().ToString("o")

    # Define parameters for the PIM activation request.
    $PIMActivationParams = @{
        principalId      = $CurrentUser.Id
        roleDefinitionId = $RoleDefinitionId
        directoryScopeId = $TenantID  # Use Tenant ID for the scope
        action           = "SelfActivate" # Action type for self-activation
        justification    = $Justification
        scheduleInfo     = @{
            startDateTime = $StartTime
            expiration    = @{
                type = "AfterDuration"
                duration = "PT4H" # 4 hours duration
            }
        }
    }

    # Request PIM Activation with error handling
    try {
        # Attempt to create a new role assignment schedule request.
        $Activation = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $PIMActivationParams
        Write-Host "Successfully activated $($RoleDefinition.DisplayName) role via PIM for 4 hours." -ForegroundColor Green
        
        # Show currently active roles after activation
        $ActiveRoles = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '$($CurrentUser.Id)'"
        if ($ActiveRoles.Count -gt 0) {
            Write-Host "`nCurrently Active Roles (post-activation):" -ForegroundColor Green
            foreach ($activeRole in $ActiveRoles) {
                $activeRoleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "id eq '$($activeRole.RoleDefinitionId)'"
                if ($activeRoleDef) {
                    Write-Host "✔ $($activeRoleDef.DisplayName)" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "`nYou currently have no active roles." -ForegroundColor DarkGray
        }
        # ...existing code...
    } catch {
        # Capture the error message.
        $errorMessage = $_.Exception.Message
        
        # Handle specific error messages for better user feedback.
        if ($errorMessage -match "RoleAssignmentExists") {
            Write-Host "$($RoleDefinition.DisplayName) role is already active. Skipping activation." -ForegroundColor Yellow
        }
        elseif ($errorMessage -match "PendingRoleAssignmentRequest") {
            Write-Host "There is already a pending activation request for the $($RoleDefinition.DisplayName) role. Please wait for it to complete." -ForegroundColor Yellow
        }
        else {
            Write-Host "Failed to activate role: $errorMessage" -ForegroundColor Red
        }
    }
    
    # Ask if the user wants to activate another role
    $Continue = Read-Host "Do you want to activate another role? (Y/N)"
    if ($Continue -match "^[Nn]$" ) {
        Write-Host "Exiting script." -ForegroundColor Green
        exit
    }
}
# End of script
