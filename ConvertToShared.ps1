﻿<#
Author: Eric Sobkowicz
Created: December 21, 2017
Last Updated By: Eric Sobkowicz
Last Updated: January 9, 2018

Purpose: 
    To properly convert a given user mailbox to a shared mailbox by migrating it to the on prem exchange server, converting it, then migrating it back to O365

Requirements: 
    Hybrid Exchange environment, RSAT tools installed on the system running the script.
    MSOL module installed for connecting to azure AD.
    All computer names should be the short name, not the FQDN, if the FQDN is needed they will be combined in the script with the domain name in the $ADDomain variable.

Variables:
    $ExchangeServer - The computer name of the Exchange server
    $SyncServer - The computer name of the Azure AD sync server
    $ADDomain - The local AD domain
    $EmailDomain - The local email domain
    $O365Domain - The .onmicrosoft.com domain for your O365 tennant
    $MigrationEndpoint - The DNS address of your O365 Migration Endpoint, this can be easily viewed in the O365 GUI by doing a manual migration
    $Database - Local On Prem Exchange Database name

#>
# Treats every error as a terminating error, supresses warnings generated by connecting to O365 commands etc.
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

# Variables
$ExchangeServer = "ExchangeServerName"
$SyncServer = "SyncserverName"
$ADDomain = "ADDomainName"
$EmailDomain = "Local Email Domain"
$O365Domain = "client.onmicrosoft.com"
$MigrationEndpoint = "ExternalMigrationEndpointFQDN"
$Database = "Exchange OnPrem Database Name"

function main
{
# Creates some blank space at the top of the console window so that the progress bars futher in don't hide the various text outputs.
Write-Host "






"

# Checks to see if the local and O365 creds are the same, prompts user for credentials.
$A = "a"
while (($A -ne "Y") -and ($A -ne "N")) 
    {
    $A = Read-Host "Are the local credentials and the O365 credentials different?(Y/N)"
    If ($A -eq "Y")
        {
        $Cred = Get-Credential -Message "Please enter the Office 365 credentials (username@domain)"
        $LocalCred = Get-Credential -Message "Please enter the Domain Admin credentials (username@domain)"
        }
    elseif ($A -eq "N")
        {
        $Cred = Get-Credential -Message "Please enter the admin credentials (username@domain)"
        $LocalCred = $Cred
        }
    else
        {
        Write-Host "You have entered an invalid selection, please enter Y for Yes or N for No" -ForegroundColor Red
        }
    }

# Call the Check-Credentials function to verify the credentials are o.k. before continuing.
Check-Credentials

# Asks the admin for the account name and checks to see if it exists, if it does not the script writes an error message and ends.
$Alias = Read-Host "Please enter the account name"
try
	{
	Get-ADUser $Alias | Out-Null
	}
catch
	{
	Write-Host "The user you have entered does not exist, please ensure you have the correct username and re-run the script." -ForegroundColor Red
	Exit
	}
Write-Host "The user is valid." -ForegroundColor Green

# Connect to O365 and check the current migration status, gives user feedback based on where the migration is, requests permission to continue.
$Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
Import-PSSession $Session | Out-Null

# Gets the user RecipientType to check if the mailbox is onprem or in O365
Write-Host "Checking the current type, location, and migration status of the mailbox." -ForegroundColor Magenta
$RecipientType = (Get-Recipient $Alias).RecipientType

# Mailbox is in O365
If ($RecipientType -eq "UserMailbox")
    {
    # Gets the mailbox RecipientTypeDetails to check if the mailbox is a User or Shared mailbox
    $RecipientTypeDetails = (Get-Mailbox $Alias).RecipientTypeDetails
    
    # Mailbox is a user mailbox in O365, output to user and request permission to continue, if they accept perform the conversion to a shared mailbox.
    if ($RecipientTypeDetails -eq "UserMailbox")
        {
        Write-Host "The mailbox is currently a User Mailbox in O365, it will be converted to a Shared Mailbox." -ForegroundColor Magenta
        
        # Call the Check-Migration Function to Check for any existing migrations for the mailbox and output to the user if there are
        Check-MigrationStatus
        Remove-PSSession $Session | Out-Null

        # Call the Migrate-Mailbox function to migrate the mailbox to on prem, deletes the migration batch once done.
        Migrate-Mailbox -Cred $Cred -LocalCred $LocalCred -Alias $Alias -MigrationEndpoint $MigrationEndpoint -O365Domain $O365Domain -Direction "To OnPrem" -EmailDomain $EmailDomain -Database $Database
        
        # Creates a PS session to the local exchange server, converts the mailbox to a shared mailbox.
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$ADDomain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
        Import-PSSession $Session | Out-Null
        Write-Host "Converting mailbox to shared mailbox" -ForegroundColor Magenta
        try
            {
            Set-Mailbox -Identity $Alias -Type Shared | Out-Null
            }
        catch
            {
            Write-Host "Script failed during the mailbox conversion step, exiting script." -ForegroundColor Red
            Remove-PSSession $Session | Out-Null
            Exit
            }
        Remove-PSSession $Session | Out-Null

        # Waits 5 minutes for AD replication to take place, then kicks off the sync to O365, then waits for 10 Minutes for it to complete and replicate between the pods.
        Create-ProgressBar -Time 300 -Message "Waiting for AD Replication"
        Invoke-Command {Start-ADSyncSyncCycle -PolicyType Delta} -computer "$SyncServer.$ADDomain"
        Create-ProgressBar -Time 600 -Message "Waiting for O365 Replication"

        # Call the Migrate-Mailbox function to migrate the mailbox back to the cloud, deletes the migration batch once done.
        Migrate-Mailbox -Cred $Cred -LocalCred $LocalCred -Alias $Alias -MigrationEndpoint $MigrationEndpoint -O365Domain $O365Domain -Direction "To O365"

        # Call the Remove-Licenses function to remove all licenses from the mailbox as they are no longer needed.
        Remove-Licenses -Cred $Cred -UPN "$Alias@$EmailDomain"

        # Connects to O365, verifies the mailbox type and outputs final success message.
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
        Import-PSSession $Session | Out-Null
        Write-Host "The script has completed successfully, the mailbox is now type: $((Get-Mailbox -Identity $Alias).RecipientTypeDetails) " -ForegroundColor Green
        Remove-PSSession $Session | Out-Null
        }
    # Mailbox is a shared mailbox in O365, output to user and request permission to continue, if they accept perform the conversion to a user mailbox.
    elseif ($RecipientTypeDetails -eq "SharedMailbox")
        {
        Write-Host "The mailbox is currently a Shared Mailbox in O365, it will be converted to a User Mailbox." -ForegroundColor Magenta
         
        # Check for any existing migrations for the mailbox and output to the user if there are.
        Check-MigrationStatus
        Remove-PSSession $Session | Out-Null

        # Call the Migrate-Mailbox function to migrate the mailbox to on prem, deletes the migration batch once done.
        Migrate-Mailbox -Cred $Cred -LocalCred $LocalCred -Alias $Alias -MigrationEndpoint $MigrationEndpoint -O365Domain $O365Domain -Direction "To OnPrem" -EmailDomain $EmailDomain -Database $Database
        
        # Creates a PS session to the local exchange server, converts the mailbox to a user mailbox.
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$ADDomain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
        Import-PSSession $Session | Out-Null
        Write-Host "Converting mailbox to user mailbox" -ForegroundColor Magenta
        try
            {
            Set-Mailbox -Identity $Alias -Type Regular | Out-Null
            }
        catch
            {
            Write-Host "Script failed during the mailbox conversion step, exiting script." -ForegroundColor Red
            Remove-PSSession $Session | Out-Null
            Exit
            }
        Remove-PSSession $Session | Out-Null

        # Waits 5 minutes for AD replication to take place, then kicks off the sync to O365, then waits for 10 Minutes for it to complete and replicate between the pods.
        Create-ProgressBar -Time 300 -Message "Waiting for AD Replication"
        Invoke-Command {Start-ADSyncSyncCycle -PolicyType Delta} -computer "$SyncServer.$ADDomain"
        Create-ProgressBar -Time 600 -Message "Waiting for O365 Replication"

        # Call the Migrate-Mailbox function to migrate the mailbox back to the cloud, deletes the migration batch once done.
        Migrate-Mailbox -Cred $Cred -LocalCred $LocalCred -Alias $Alias -MigrationEndpoint $MigrationEndpoint -O365Domain $O365Domain -Direction "To O365"
        
        # Call the Apply-O365License function to apply a license to the mailbox.
        Apply-O365License -Cred $Cred -UPN "$Alias@$EmailDomain"

        # Connects to O365, verifies the mailbox type and outputs final success message.
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
        Import-PSSession $Session | Out-Null
        Write-Host "The script has completed successfully, the mailbox is now type: $((Get-Mailbox -Identity $Alias).RecipientTypeDetails) " -ForegroundColor Green
        Remove-PSSession $Session | Out-Null
        }
    
    # Mailbox is of a type unsupported by the script, exits the script after throwing an error.
    else 
        {
        Write-Host "The Mailbox is the unsupported type: $RecipientTypeDetails Exiting script." -ForegroundColor Red
        Exit
        }
    }
# Mailbox is on prem.
elseif ($RecipientType -eq "MailUser")
    {
    Write-Host "The mailbox is already on prem, checking for existing migrations." -ForegroundColor Magenta
    
    # Check for any existing migrations for the mailbox and output to the user if there are.
    Check-MigrationStatus
    Remove-PSSession $Session | Out-Null
     
    # End the connection to O365 and open up a connection to the local Exchange server.
    Remove-PSSession $Session | Out-Null
    $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$ADDomain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
    Import-PSSession $Session | Out-Null
        
    # Gets the mailbox RecipientTypeDetails to check if the mailbox is a User or Shared mailbox.
    $RecipientTypeDetails = (Get-Mailbox $Alias).RecipientTypeDetails
    Remove-PSSession $Session | Out-Null
    
    # Mailbox is a user mailbox on prem, output to user and request permission to continue, find out which direction the conversion is going and finish it.
    if ($RecipientTypeDetails -eq "UserMailbox")
        {
        Write-Host "The mailbox is currently a user mailbox located on prem." -ForegroundColor Magenta
        }
    
    # Mailbox is a shared mailbox on prem, output to user and request permission to continue, find out which direction the conversion is going and finish it.
    elseif ($RecipientTypeDetails -eq "SharedMailbox")
        {
        Write-Host "The mailbox is currently a shared mailbox located on prem." -ForegroundColor Magenta
        }
    
    # Mailbox is of a type unsupported by the script, exits the script after throwing an error.
    else 
        {
        Write-Host "The mailbox is the unsupported type: $RecipientTypeDetails Exiting script." -ForegroundColor Red
        Remove-PSSession $Session | Out-Null
        Exit
        }

    # Find out from the user if this is an interrupted conversion from a user to a shared mailbox, or from a shared to a user mailbox.
    $B = "a"
    $ConversionDirection = ""
    while (($B -ne "Y") -and ($B -ne "N"))
        {
        $B = Read-Host "Is this an interrupted conversion of a user mailbox to a shared mailbox? (Y/N)"
        if ($B -eq "Y")
            {
            Write-Host "Continuing conversion of user mailbox to shared mailbox" -ForegroundColor Magenta
            $ConversionDirection = "ToShared"
            }
        elseif ($B -eq "N")
            {
            $C = "a"
            while (($C -ne "Y") -and ($C -ne "N"))
                {
                $C = Read-Host "Is this an interrupted conversion of a shared mailbox to a user mailbox? (Y/N)"
                if ($C -eq "Y")
                    {
                    Write-Host "Continuing conversion of shared mailbox to user mailbox" -ForegroundColor Magenta
                    $ConversionDirection = "ToUser"
                    }
                elseif ($C -eq "N")
                    {
                    Write-Host "This is an unsupported scenario, exiting script" -ForegroundColor Red
                    Exit
                    }
                else
                    {
                    Write-Host "You have entered an invalid selection, please enter Y for Yes or N for No" -ForegroundColor Red
                    }
                }
            }
        else
            {
            Write-Host "You have entered an invalid selection, please enter Y for Yes or N for No" -ForegroundColor Red
            }
        }
    
    # Finish Conversion to shared mailbox if needed.
    if (($ConversionDirection -eq "ToShared") -and ($RecipientTypeDetails -eq "UserMailbox"))
        {
        # Creates a PS session to the local exchange server, converts the mailbox to a shared mailbox.
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$ADDomain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
        Import-PSSession $Session | Out-Null
        Write-Host "Converting mailbox to shared mailbox" -ForegroundColor Magenta
        try
            {
            Set-Mailbox -Identity $Alias -Type Shared | Out-Null
            }
        catch
            {
            Write-Host "Script failed during the mailbox conversion step, exiting script." -ForegroundColor Red
            Remove-PSSession $Session | Out-Null
            Exit
            }
        Remove-PSSession $Session | Out-Null

        # Waits 5 minutes for AD replication to take place, then kicks off the sync to O365, then waits for 10 Minutes for it to complete and replicate between the pods.
        Create-ProgressBar -Time 300 -Message "Waiting for AD Replication"
        Invoke-Command {Start-ADSyncSyncCycle -PolicyType Delta} -computer "$SyncServer.$ADDomain"
        Create-ProgressBar -Time 600 -Message "Waiting for O365 Replication"
        }

    # Finish conversion to user mailbox if needed.
    if (($ConversionDirection -eq "ToUser") -and ($RecipientTypeDetails -eq "SharedMailbox"))
        {
         # Creates a PS session to the local exchange server, converts the mailbox to a shared mailbox.
         $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$ADDomain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
         Import-PSSession $Session | Out-Null
         Write-Host "Converting mailbox to user mailbox" -ForegroundColor Magenta
         try
             {
             Set-Mailbox -Identity $Alias -Type Regular | Out-Null
             }
         catch
             {
             Write-Host "Script failed during the mailbox conversion step, exiting script." -ForegroundColor Red
             Remove-PSSession $Session | Out-Null
             Exit
             }
         Remove-PSSession $Session | Out-Null
 
         # Waits 5 minutes for AD replication to take place, then kicks off the sync to O365, then waits for 10 Minutes for it to complete and replicate between the pods.
         Create-ProgressBar -Time 300 -Message "Waiting for AD Replication"
         Invoke-Command {Start-ADSyncSyncCycle -PolicyType Delta} -computer "$SyncServer.$ADDomain"
         Create-ProgressBar -Time 600 -Message "Waiting for O365 Replication"
        }

    # Call the Migrate-Mailbox function to migrate the mailbox back to the cloud, deletes the migration batch once done.
    Migrate-Mailbox -Cred $Cred -LocalCred $LocalCred -Alias $Alias -MigrationEndpoint $MigrationEndpoint -O365Domain $O365Domain -Direction "To O365"

    if ($ConversionDirection -eq "ToShared")
        {
        # Call the Remove-Licenses function to remove all licenses from the mailbox as they are no longer needed.
        Remove-Licenses -Cred $Cred -UPN "$Alias@$EmailDomain"
        }
    if ($ConversionDirection -eq "ToUser")
        {
        # Call the Apply-O365License function to apply a license to the mailbox.
        Apply-O365License -Cred $Cred -UPN "$Alias@$EmailDomain" 
        }

    # Connects to O365, verifies the mailbox type and outputs final success message.
    $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
    Import-PSSession $Session | Out-Null
    Write-Host "The script has completed successfully, the mailbox is now type: $((Get-Mailbox -Identity $Alias).RecipientTypeDetails) " -ForegroundColor Green
    Remove-PSSession $Session | Out-Null
    }

# Mailbox is of a type unsupported by the script, exits the script after throwing an error.
else
    {
    Write-Host "The Mailbox is the unsupported type: $RecipientType Exiting script." -ForegroundColor Red
    Remove-PSSession $Session | Out-Null
    Exit    
    }
}

<#
Purpose: 
    This function checks to see if a migration currently exists for the user or not.  It provides a checkpoint for if the user wishes to continue.

Requirements:
    A connection to an O365 PS session

Variables:
    N/A
#>
function Check-MigrationStatus 
{
$MigrationTest = $null
$MigrationTest = Get-MoveRequest $Alias -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($MigrationTest))
    {
    $Answer = "a"
    While ($Answer -ne "Y")
        {
        $Answer = Read-Host "There are no existing migrations for this user, would you like to continue? (Y/N): "
        If ($Answer -eq "N")
            {
            Write-Host "You have selected not to continue, exiting script, no changes have been made." -ForegroundColor Red
            Remove-PSSession $Session | Out-Null
            Exit
            }
        If ($Answer -ne "Y")
            {
            Write-Host "You have entered an invalid selection, please enter Y for Yes or N for No" -ForegroundColor Yellow
            }
        }
    Write-Host " "
    }
else
    {
    if ((Get-MoveRequest $Alias | Get-MoveRequestStatistics).PercentComplete -ne 100)
        {
        Write-Host "There is an in progress migration for this user, the current status is as follows: " -ForegroundColor Red
        Get-MoveRequest $Alias | Get-MoveRequestStatistics | Format-Table DisplayName, StatusDetail, TotalMailboxSize, TotalArchiveSize, PercentComplete
        Write-Host "The script cannot run while there is an ongoing migration, exiting script." -ForegroundColor Red
        Remove-PSSession $Session | Out-Null
        Exit
        }
    $Answer = "a"
    While ($Answer -ne "Y")
        {
        Write-Host "There is an existing migration batch for this mailbox, here is its current status:" -ForegroundColor Magenta
        Get-MoveRequest $Alias | Get-MoveRequestStatistics | Format-Table DisplayName, StatusDetail, TotalMailboxSize, TotalArchiveSize, PercentComplete
        $Answer = Read-Host "Would you like to continue with the conversion, this will delete the existing migration batch? (Y/N): "
        If ($Answer -eq "N")
            {
            Write-Host "You have selected not to continue, exiting script, no changes have been made." -ForegroundColor Red
            Remove-PSSession $Session | Out-Null
            Exit
            }
        If ($Answer -ne "Y")
            {
            Write-Host "You have entered an invalid selection, please enter Y for Yes or N for No" -ForegroundColor Yellow
            }
        }    
    Write-Host "Removing the old Migration Batch" -ForegroundColor Magenta
    Get-MoveRequest -Identity $Alias | Remove-MoveRequest -Confirm:$false | Out-Null
    }
}
<#
Purpose: 
    This function waits the specified $time in seconds and creates a progress bar that shows the time remaining, percent complete, and message set with $Message

Requirements:
    None

Variables:
    $Time - the ammount of time to wait in seconds
    $Message - The message to display on the progress bar

#>
Function Create-ProgressBar ($Time, $Message)
{
For($I=$Time; $I -gt 0; $I--)
		{
		Write-Progress -Activity "$Message" -Status "Progress" -SecondsRemaining $I -PercentComplete (($Time-$I)/$Time*100)
		Start-Sleep -s 1
		}
}

<#
Purpose: 
    This function migrates the specified mailbox to O365, waits until the migration done before proceeding. During the migration a status bar will be displayed showing the current
    status detail with the percent complete represented on the progress bar.  Every 5 min the user will be given the current status of the migration and asked if they wish to continue
    waiting for the migration, the script will exit if the user enters N.  This version can migrate to or from O365 depending on the $Direction variable.

Requirements: 
    O365 powershell installed on the system running the script

Variables:
    $Cred - The O365 credentials as a PSCredential object
    $LocalCred - The Credentials for the local domain with permissions to perform the migration on the local exchange server.
    $Alias - The username of the account to be migrated
    $MigrationEndpoint - The external FQDN of the migration endpoint
    $O365Domain - The .onmicrosoft.com domain of the tennant
    $Direction - Specifies whether the migration is going to O365 or to On Prem.  Accepted values "To O365" and "To OnPrem"
    $EmailDomain - The local email domain, only needed if migrating to on prem
    $Database - The Database name of the local Exchange database, only needed if migrating to on prem.
#>

Function Migrate-Mailbox ($Cred, $LocalCred, $Alias, $MigrationEndpoint, $O365Domain, $Direction, $EmailDomain, $Database)
{
# Connect to O365
$Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
Import-PSSession $Session | Out-Null

# Check the direction variable, perform the appropriate move request command to move from O365 to on prem or from on prem to O365, exit with an error if the command throws an error.
if ($Direction -eq "To O365")
    {
    try
	    {
	    New-MoveRequest -Identity $Alias -Remote -RemoteHostName $MigrationEndpoint -TargetDeliveryDomain $O365Domain -RemoteCredential $LocalCred | Out-Null
	    }
    catch
	    {
	    Write-Host "An error occured creating the mailbox migration." -ForegroundColor Red
	    Exit
	    }
    }
elseif ($Direction -eq "To OnPrem")
    {
    try
	    {
	    New-MoveRequest -Identity $Alias -Outbound -RemoteTargetDatabase $Database -RemoteHostName $MigrationEndpoint -TargetDeliveryDomain $EmailDomain -RemoteCredential $LocalCred | Out-Null
	    }
    catch
	    {
	    Write-Host "An error occured creating the mailbox migration." -ForegroundColor Red
	    Exit
	    }
    }
# Throw an error and exit the script if the direction is not set correctly.
else
    {
    Write-Host "The value $Direction for the `$Direction variable is an invalid entry, exiting script" -ForegroundColor Red
    Exit
    }
# Show a progress bar while the migration is being done, check with the user every 5 min if the migration is still ongoing to see if they want to wait or exit the script.
$MoveRequestStatistics = Get-MoveRequest $Alias | Get-MoveRequestStatistics
While ($MoveRequestStatistics.PercentComplete -ne 100)
    {
    $MoveRequestStatistics = Get-MoveRequest $Alias | Get-MoveRequestStatistics
    Write-Progress -Activity "Waiting for Mailbox Migration" -Status $MoveRequestStatistics.StatusDetail.Value -PercentComplete $MoveRequestStatistics.PercentComplete
    Start-Sleep -s 4
    $i ++
    If ($i%60 -eq 0)
        {
        Write-Host "The current status of the migration is:"
        Get-MoveRequest $Alias | Get-MoveRequestStatistics | Format-Table DisplayName, StatusDetail, TotalMailboxSize, TotalArchiveSize, PercentComplete
        $Answer = Read-Host "Would you like to wait another 5min for the Migration to complete? (Y/N)"
        If ($Answer -eq "N")
            {
            Write-Host "You have selected not to wait, the script will now exit, you will need to manually complete the migration and any other pending tasks" -ForegroundColor Red
            Exit
            }
        }
    }
# Output the final status of the migration once it completes, delete the migration batch, close the connection to O365 and return from the function.
Write-Host "The migration has completed, here is the final status of the migration:" -ForegroundColor Green
Get-MoveRequest $Alias | Get-MoveRequestStatistics | Format-Table DisplayName, StatusDetail, TotalMailboxSize, TotalArchiveSize, PercentComplete
Get-MoveRequest -Identity $Alias | Remove-MoveRequest -Confirm:$false | Out-Null

Remove-PSSession $Session | Out-Null
}

<#
Purpose: 
    Takes a given user and removes all licenses associated with them.

Requirements: 
    Need to have the MSOnline module installed on the system running the script.

Variables:
    $Cred - O365 admin credentials as a PS credential object
    $UPN - the User Principal Name of the user to remove the licenses from in format username@domain
#>

function Remove-Licenses ($Cred, $UPN)
{
# Import the MSOnline module and connect to Azure AD
Import-Module MSOnline | Out-Null
Connect-MsolService -Credential $Cred

# List the licenses applied to the user.
Write-Host "The current licensing applied to the selected user is as follows:" -ForegroundColor Magenta
Get-MsolUser -UserPrincipalName $UPN | Format-Table UserPrincipalName, DisplayName, IsLicensed, Licenses

# Asks the end user if they want to remove all the licenses, if they enter an incorrect value it throws a warning and asks again, if they enter N then it exits the script, continues on Y.
While ($Choice -ne "Y")
    {
    $Choice = Read-Host "Would you like to remove all listed licenses (Y/N): "
    If ($Choice -eq "N")
        {
        Write-Host "You have chosen to not remove the licenses from the user $UPN, exiting script."-ForegroundColor Red
        Exit
        }
    If ($Choice -ne "Y")
        {
        Write-Host "You have entered an invalid entry, please enter Y for Yes or N for No." -ForegroundColor Red
        }
}

# Pulls a list of licenses attached to the user and removes all of them.
try
    {
    (Get-MsolUser -UserPrincipalName $UPN).licenses.AccountSkuId | ForEach-Object{Set-MsolUserLicense -UserPrincipalName $upn -RemoveLicenses $_}
    }
catch
    {
    Write-Host "A problem occured during the removal of the licenses, exiting script." -ForegroundColor Red
    Exit
    }

# Lets the user know that the removal is finished and ouputs the current licensing status of the mailbox.
Write-Host "The license removal was successful, here is the current license status of the maibox:" -ForegroundColor Green
Get-MsolUser -UserPrincipalName $UPN | Format-Table UserPrincipalName, DisplayName, IsLicensed, Licenses
}

<#
Purpose: 
    Take a user UPN, connect to Azure AD, display a list of available licenses and their count, add the license the user chooses to the account.

Requirements: 
    Azure AD powershell module needs to be installed on the computer running the script.

Variables:
    $Cred - The O365 admin credentials passed as a credential object.
    $UPN - The User Principal name of the user to apply the license to.
#>

Function Apply-O365License ($Cred, $UPN)
{
# Import the MSOnline module and connect to Azure AD
Import-Module MSOnline | Out-Null
Connect-MsolService -Credential $Cred
# Get a list of all Possible licenses to apply
$Licenses = Get-MsolAccountSku | Where-Object {$_.ActiveUnits -ne 0 -and $_.ActiveUnits -lt 1000}

# Create a menu object and populate it with the MenuNumber, AccountSkuID, and Available License Count
$Menu = @([psobject])
$MenuNumber = 1
foreach ($License in $Licenses)
    {
    $MenuItem = New-Object psobject
    $MenuItem | Add-Member -Type NoteProperty -Name MenuNumber -Value $MenuNumber
    $MenuItem | Add-Member -Type NoteProperty -Name AccountSkuID -Value $License.AccountSkuID
    $MenuItem | Add-Member -Type NoteProperty -Name AvailableLicenses -Value ($License.ActiveUnits - $License.ConsumedUnits)
    $Menu += $MenuItem
    $MenuNumber ++
    }

# Display Menu for the user and ask which license they would like to apply, exit function if they enter N.
Write-Host "The current licensing applied to the selected user is as follows:" -ForegroundColor Magenta
Get-MsolUser -UserPrincipalName $UPN | Format-Table DisplayName, Licenses
Write-Host "Here are the available license(s):" -ForegroundColor Magenta
$Menu | Format-Table MenuNumber, AccountSkuID, AvailableLicenses
$Choice = Read-Host "Please enter the MenuNumber of the license you would like to apply, this will overwrite any existing licenses. Enter N to exit without making changes."
if ($Choice -eq "N")
    {
    Write-Host "Exiting license application, no changes have been made." -ForegroundColor Red
    Exit
    }
$SelectedLicense = $Menu | Where-Object {$_.MenuNumber -eq $Choice}
Write-Host "Applying $($SelectedLicense.AccountSkuID) to user $UPN." -ForegroundColor Magenta

try
	{
	Set-MsolUser -UserPrincipalName $UPN -UsageLocation "CA"
	Set-MsolUserLicense -UserPrincipalName $UPN -AddLicenses $SelectedLicense.AccountSkuID
	}
catch
	{
	Write-Host "An error occured during the application of the license." -ForegroundColor Red
	Exit
	}
Write-Host "The license $($SelectedLicense.AccountSkuID) has been applied succesfully to the user $UPN. Here is the new license status of the user:" -ForegroundColor Green
Get-MsolUser -UserPrincipalName $UPN | Format-Table DisplayName, Licenses
}

<#
Purpose: 
    Checks the entered credentials and makes sure they are valid before continuing.

Requirements: 
    O365 Powershell installed on the system running the script.
    $Cred and $LocalCred in use as the credential objects.

Variables:
    N/A

#>
function Check-Credentials {
# Check the O365 credentials to make sure they are valid. If they are not valid outputs an error message and has the user re-enter them then checks them again.
$Continue = "N"
While ($Continue -eq "N")
    {
    try 
        {
        Write-Host "Checking the O365 credentials." -ForegroundColor Magenta
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
        Import-PSSession $Session | Out-Null
        Remove-PSSession $Session | Out-Null
        $Continue = "Y"
        Write-Host "Successfully connected to O365 with the given credentials." -ForegroundColor Green
        }
    catch 
        {
        Write-Host "There is an issue with the O365 credentials that were entered please check the password and ensure you are using the full domain (user@domain) in the username" -ForegroundColor Red
        Remove-PSSession $Session | Out-Null
        $Cred = Get-Credential -Message "Please enter the Office 365 credentials (username@domain)"
        $Continue = "N"
        }
    }
# Check the local credentials to make sure they are valid.  If they are not valid outputs an error message and has the user re-enter them then checks them again.
$Continue = "N"
While ($Continue -eq "N")
    {
    try
        {
        Write-Host "Checking the local credentials." -ForegroundColor Magenta
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$ADDomain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
        Import-PSSession $Session | Out-Null
        Remove-PSSession $Session | Out-Null
        $Continue = "Y"
        Write-Host "Succesfully connected to the local exchange server with the given credentials." -ForegroundColor Green
        }
    catch 
        {
        Write-Host "There is an issue with the local credentials that were entered please check that you entered the username and password correctly." -ForegroundColor Red
        Remove-PSSession $Session | Out-Null
        $LocalCred = Get-Credential -Message "Please enter the Domain Admin credentials (username@domain)"
        $Continue = "N"
        }
    }
}
   
# Runs the Main function
# Putting the main code within a function and calling it at the end of the script allows for the main code to be at the top of the script and all other functions below it
Main