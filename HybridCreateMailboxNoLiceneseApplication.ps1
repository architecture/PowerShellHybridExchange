<#
Author: Eric Sobkowicz
Created: December 20, 2017
Last Updated By: Eric Sobkowicz
Last Updated: December 27, 2017

Purpose: This script creates a mailbox on a local exchange server for an existing AD user, syncs the changes to O365, and migrates the mailbox to O365.

Requirements: Hybrid O365 exchange environement running a version of Azure AD Sync that supports the "Start-ADSyncCycle" command.

Variables: All variables that need to be set are under the Variables section at the top of the script, they are client specific and need to be updated on a per client basis.

$ExchangeServer - The computer name of the Exchange server
$SyncServer - The computer name of the Azure AD sync server
$Domain - The local AD domain
$O365Domain - The .onmicrosoft.com domain for your O365 tennant
$MigrationEndpoint - The DNS address of your O365 Migration Endpoint, this can be easily viewed in the O365 GUI by doing a manual migration

All computer names should be the short name, not the FQDN, if the FQDN is needed they will be combined in the script with the domain name in the $Domain variable.
#>

# Treats every error as a terminating error, supresses warnings generated by connecting to O365 commands etc.
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

# Variables
$ExchangeServer = "ExchangeServerName"
$SyncServer = "SyncserverName"
$Domain = "ADDomainName"
$O365Domain = "client.onmicrosoft.com"
$MigrationEndpoint = "ExternalMigrationEndpointFQDN"

Function main
{
# Creates some blank space at the top of the console window so that the progress bars futher in don't hide the various text outputs.
Write-Host "






"

# Prompts the user for the O365 and local Exchange Admin credentials.
$Cred = Get-Credential -Message "Please enter the Office 365 credentials (username@domain)"
$LocalCred = Get-Credential -Message "Please enter the Domain Admin credentials (username@domain)"

# Asks the user for the account name to be proecessed and checks to see if it exists, if it does not the script writes an error message and exits.
$Alias = Read-Host "Please enter the account name: "
try
	{
	Get-ADUser $Alias | Out-Null
	}
catch
	{
	Write-Host "The user you have entered does not exist, please create the user prior to running this script." -ForegroundColor Red
	Exit
	}
Write-Host "The user is valid, creating mailbox" -ForegroundColor Green

# Creates a PS session to the local exchange server and creates the mailbox, throws an error and exits the script if anything goes wrong.
$Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$ExchangeServer.$Domain/PowerShell/" -Authentication Kerberos -Credential $LocalCred
Import-PSSession $Session | Out-Null
Try
    {
    Enable-Mailbox $Alias | Out-Null
    }
Catch
    {
    Write-Host "The local mailbox creation failed" -ForegroundColor Red
    Exit
    }
Remove-PSSession $Session
Write-Host "Local mailbox creation completed sucessfully." -ForegroundColor Green

# Waits 5 minutes for AD replication to take place, then kicks off the sync to O365, then waits for 10 Minutes for it to complete and replicate between the pods.
Create-ProgressBar -Time 300 -Message "Waiting for AD Replication"
Invoke-Command {Start-ADSyncSyncCycle -PolicyType Delta} -computer "$SyncServer.$Domain"
Create-ProgressBar -Time 600 -Message "Waiting for O365 Replication"

# Call the Migrate-Mailbox function to migrate the mailbox to the cloud, deletes the migration batch once done.
Write-Host "Migrating mailbox to the cloud"
Migrate-Mailbox -Cred $Cred -LocalCred $LocalCred -Alias $Alias -MigrationEndpoint $MigrationEndpoint -O365Domain $O365Domain


# Writes a success message to the console window.
Write-Host "The mailbox creation and migration have completed successfully." -ForegroundColor Green
}

# This function waits the specified $time in seconds and creates a progress bar that shows the time remaining, percent complete, and message set with $Message
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
    waiting for the migration, the script will exit if the user enters N.  This version can only migrate to O365

Requirements: 
    O365 powershell installed on the system running the script

Variables:
    $Cred - The O365 credentials as a PSCredential object
    $LocalCred - The Credentials for the local domain with permissions to perform the migration on the local exchange server.
    $Alias - The username of the account to be migrated
    $MigrationEndpoint - The external FQDN of the migration endpoint
    $O365Domain - The .onmicrosoft.com domain of the tennant
#>
Function Migrate-Mailbox ($Cred, $LocalCred, $Alias, $MigrationEndpoint, $O365Domain)
{
# Connect to O365
$Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $Cred -Authentication Basic -AllowRedirection
Import-PSSession $Session | Out-Null
# Migrate the Mailbox based off of the global variables
try
	{
	New-MoveRequest -Identity $Alias -Remote -RemoteHostName $MigrationEndpoint -TargetDeliveryDomain $O365Domain -RemoteCredential $LocalCred | Out-Null
	}
catch
	{
	Write-Host "An error occured creating the mailbox migration." -ForegroundColor Red
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
# Output the final status of the migration once it completes, delete the migration batch, close the connection to O365, and return from the function.
Write-Host "The migration has completed, here is the final status of the migration:" -ForegroundColor Green
Get-MoveRequest $Alias | Get-MoveRequestStatistics | Format-Table DisplayName, StatusDetail, TotalMailboxSize, TotalArchiveSize, PercentComplete
Get-MoveRequest -Identity $Alias | Remove-MoveRequest -Confirm:$false | Out-Null

Remove-PSSession $Session
}

# Runs the Main function
# Putting the main code within a function and calling it at the end of the script allows for the main code to be at the top of the script and all other functions below it
Main