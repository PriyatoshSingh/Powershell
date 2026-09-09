<#

.SYNOPSIS
PSAppDeployToolkit.Extensions - Provides the ability to extend and customize the toolkit by adding your own functions that can be re-used.

.DESCRIPTION
This module is a template that allows you to extend the toolkit with your own custom functions.

This module is imported by the Invoke-AppDeployToolkit.ps1 script which is used when installing or uninstalling an application.

#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

# Set strict error handling across entire module.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1


##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

function New-ADTExampleFunction
{
    <#
    .SYNOPSIS
        Basis for a new PSAppDeployToolkit extension function.

    .DESCRIPTION
        This function serves as the basis for a new PSAppDeployToolkit extension function.

    .INPUTS
        None

        You cannot pipe objects to this function.

    .OUTPUTS
        None

        This function does not return any output.

    .EXAMPLE
        New-ADTExampleFunction

        Invokes the New-ADTExampleFunction function and returns any output.
    #>

    [CmdletBinding()]
    param
    (
    )

    begin
    {
        # Initialize function.
        Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState
    }

    process
    {
        try
        {
            try
            {
            }
            catch
            {
                # Re-writing the ErrorRecord with Write-Error ensures the correct PositionMessage is used.
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            # Process the caught error, log it and throw depending on the specified ErrorAction.
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end
    {
        # Finalize function.
        Complete-ADTFunction -Cmdlet $PSCmdlet
    }
}

function Invoke-MDYManagedDeferral
{
    <#
    .SYNOPSIS
        Provides Moody's managed in-process deferral workflow.

    .DESCRIPTION
        Provides a managed deferral workflow for application installation
        and uninstallation.

        For installation, the initial prompt displays:
        - ✔Install Now
        - ⏰Remind in 2 Hours
        - ⏰Remind in 4 Hours

        For uninstallation, the initial prompt displays:
        - ✔Uninstall Now
        - ⏰Remind in 2 Hours
        - ⏰Remind in 4 Hours

        After the initial deferral, subsequent prompts provide the primary
        deployment action and an additional two-hour reminder.

        The function automatically determines the action from:
        $ADTSession.DeploymentType

        If DeploymentType is Uninstall, uninstallation wording is used.
        Install wording is used for Install, empty, null, or unexpected values.

        The final deadline and selected reminder information are retained
        in the native PSADT defer-history registry.

        The deployment remains active during the selected deferral period
        and does not exit with code 1602.

        The workflow is only displayed when one or more processes configured
        in AppProcessesToClose are running.

        After the final deadline, the native PSADT process-close dialog is
        displayed with a configurable final countdown.

    .PARAMETER ADTSession
        The active PSADT deployment session.

    .PARAMETER DeferDeadlineHours
        Total deferral window in hours.

    .PARAMETER InitialTwoHourDeferHours
        Duration of the initial short deferral option.

    .PARAMETER InitialFourHourDeferHours
        Duration of the initial long deferral option.

    .PARAMETER SubsequentDeferHours
        Duration of subsequent deferrals after the initial choice.

    .PARAMETER PostDeadlineCloseCountdownSeconds
        Final process-close countdown after the deadline expires.

    .PARAMETER DeferralSleepCheckSeconds
        Maximum number of seconds between reminder-time checks.

    .NOTES
        This function intentionally keeps the deployment process running
        during deferral.

        Configure the Intune installation timeout to accommodate the complete
        deferral window, final countdown, and deployment execution time.

        Save the Extensions module as UTF-8 with BOM to preserve the ✔ and ⏰
        characters under Windows PowerShell 5.1.
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$ADTSession,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 168)]
        [int]$DeferDeadlineHours = 8,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 24)]
        [int]$InitialTwoHourDeferHours = 2,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 24)]
        [int]$InitialFourHourDeferHours = 4,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 24)]
        [int]$SubsequentDeferHours = 2,

        [Parameter(Mandatory = $false)]
        [ValidateRange(60, 86400)]
        [int]$PostDeadlineCloseCountdownSeconds = 1800,

        [Parameter(Mandatory = $false)]
        [ValidateRange(10, 3600)]
        [int]$DeferralSleepCheckSeconds = 300
    )

    try
    {
        ##================================================
        ## MARK: Determine Deployment Action
        ##================================================

        switch ([string]$ADTSession.DeploymentType)
        {
            'Uninstall'
            {
                $DeploymentAction = 'Uninstall'
                $ActionDescription = 'uninstallation'
                $ActionNowButtonText = '✔Uninstall Now'
                $ActionTitle = "$($ADTSession.AppName) Uninstall"

                $InitialActionMessage = 'Select a reminder option or start the uninstallation now.'
                $SubsequentActionMessage = 'You may defer for another two hours or start the uninstallation now.'

                $ProcessCloseSubtitle = "$($ADTSession.AppName) must be closed before the uninstallation can continue"
            }

            default
            {
                $DeploymentAction = 'Install'
                $ActionDescription = 'installation'
                $ActionNowButtonText = '✔Install Now'
                $ActionTitle = "$($ADTSession.AppName) Install"

                $InitialActionMessage = 'Select a reminder option or start the installation now.'
                $SubsequentActionMessage = 'You may defer for another two hours or start the installation now.'

                $ProcessCloseSubtitle = "$($ADTSession.AppName) must be closed before the installation can continue"
            }
        }

        Write-ADTLogEntry -Message "Managed deferral deployment action resolved as [$DeploymentAction]."

        ##================================================
        ## MARK: Validate Deployment Mode
        ##================================================

        $CurrentDeployMode = [string]$ADTSession.DeployMode

        if ($CurrentDeployMode -in @('Silent', 'NonInteractive'))
        {
            Write-ADTLogEntry `
                -Message "The managed deferral workflow cannot display prompts because the deployment is running in [$CurrentDeployMode] mode. Continuing without deferral." 

            return
        }

        ##================================================
        ## MARK: Check for Impacted Processes
        ##================================================

        if (
            -not $ADTSession.AppProcessesToClose -or
            $ADTSession.AppProcessesToClose.Count -eq 0
        )
        {
            Write-ADTLogEntry -Message 'No processes are configured in AppProcessesToClose. The managed deferral workflow will be skipped.'

            return
        }

        $RunningImpactedProcesses = @(
            Get-ADTRunningProcesses `
                -ProcessObjects $ADTSession.AppProcessesToClose
        )

        if ($RunningImpactedProcesses.Count -eq 0)
        {
            Write-ADTLogEntry -Message 'None of the configured impacted processes are running. The managed deferral workflow will be skipped.'

            return
        }

        $RunningProcessNames = @(
            $RunningImpactedProcesses |
                ForEach-Object { $_.Name } |
                Sort-Object -Unique
        ) -join ', '

        Write-ADTLogEntry -Message "Detected impacted process(es): [$RunningProcessNames]. Starting the managed [$ActionDescription] deferral workflow."

        ##================================================
        ## MARK: Configure Button Labels
        ##================================================

        $TwoHourButtonText = '⏰Remind in 2 Hours'
        $FourHourButtonText = '⏰Remind in 4 Hours'

        ##================================================
        ## MARK: Configure Defer History
        ##================================================

        $DeferHistoryPath = "HKLM:\SOFTWARE\PSAppDeployToolkit\DeferHistory\$($ADTSession.InstallName)"

        $DeferHistory = Get-ItemProperty `
            -LiteralPath $DeferHistoryPath `
            -ErrorAction SilentlyContinue

        ##================================================
        ## MARK: Create or Reuse Final Deadline
        ##================================================

        if ($DeferHistory -and $DeferHistory.DeferDeadline)
        {
            try
            {
                $DeferDeadline = [datetime]$DeferHistory.DeferDeadline

                Write-ADTLogEntry -Message "Reusing the existing [$ActionDescription] deferral deadline [$DeferDeadline]."
            }
            catch
            {
                $DeferDeadline = (Get-Date).AddHours(
                    $DeferDeadlineHours
                )

                Set-ADTDeferHistory `
                    -DeferDeadline $DeferDeadline

                Write-ADTLogEntry -Message "The stored deferral deadline was invalid. Created a new deadline [$DeferDeadline]."
            }
        }
        else
        {
            $DeferDeadline = (Get-Date).AddHours(
                $DeferDeadlineHours
            )

            Set-ADTDeferHistory `
                -DeferDeadline $DeferDeadline

            Write-ADTLogEntry -Message "Created the initial [$ActionDescription] deferral deadline [$DeferDeadline]."
        }

        ##================================================
        ## MARK: Restore Existing Deferral State
        ##================================================

        $InitialDeferralUsed = $false
        $NextPromptTime = $null

        if (
            $DeferHistory -and
            $DeferHistory.DeferRunInterval -and
            $DeferHistory.DeferRunIntervalLastTime
        )
        {
            $InitialDeferralUsed = $true

            try
            {
                $StoredInterval = [timespan]$DeferHistory.DeferRunInterval
                $LastDeferralTime = [datetime]$DeferHistory.DeferRunIntervalLastTime

                $NextPromptTime = $LastDeferralTime.Add(
                    $StoredInterval
                )

                if ($NextPromptTime -gt $DeferDeadline)
                {
                    $NextPromptTime = $DeferDeadline
                }

                if ($NextPromptTime -le (Get-Date))
                {
                    Write-ADTLogEntry -Message "The previously selected reminder time [$NextPromptTime] has already passed."

                    $NextPromptTime = $null
                }
                else
                {
                    Write-ADTLogEntry -Message "Restored the existing reminder time [$NextPromptTime] from PSADT defer history."
                }
            }
            catch
            {
                $NextPromptTime = $null

                Write-ADTLogEntry `
                    -Message "The existing reminder information could not be restored. Error: $($_.Exception.Message)"
                    
            }
        }

        $ProceedWithDeployment = $false
        $FinalEnforcementDisplayed = $false

        ##================================================
        ## MARK: Main Deferral Loop
        ##================================================

        while (-not $ProceedWithDeployment)
        {
            $CurrentTime = Get-Date

            ##================================================
            ## MARK: Wait Until Selected Reminder Time
            ##================================================

            if (
                $NextPromptTime -and
                $CurrentTime -lt $NextPromptTime
            )
            {
                $RemainingSeconds = [int][System.Math]::Ceiling(
                    ($NextPromptTime - $CurrentTime).TotalSeconds
                )

                Write-ADTLogEntry -Message "The [$ActionDescription] is deferred until [$NextPromptTime]. Approximately [$RemainingSeconds] seconds remain."

                while ((Get-Date) -lt $NextPromptTime)
                {
                    $RemainingSeconds = [int][System.Math]::Ceiling(
                        ($NextPromptTime - (Get-Date)).TotalSeconds
                    )

                    if ($RemainingSeconds -le 0)
                    {
                        break
                    }

                    $SleepSeconds = [int][System.Math]::Min(
                        $RemainingSeconds,
                        $DeferralSleepCheckSeconds
                    )

                    if ($SleepSeconds -le 0)
                    {
                        break
                    }

                    Start-Sleep -Seconds $SleepSeconds
                }

                Write-ADTLogEntry -Message 'The selected deferral period has expired. Displaying the deployment prompt again.'

                $NextPromptTime = $null

                continue
            }

            $CurrentTime = Get-Date

            ##================================================
            ## MARK: Final Enforcement
            ##================================================

            if ($CurrentTime -ge $DeferDeadline)
            {
                Write-ADTLogEntry -Message "The final [$ActionDescription] deadline [$DeferDeadline] has expired. Displaying the final application-close countdown of [$PostDeadlineCloseCountdownSeconds] seconds."

                $FinalWelcomeParams = @{
                    CloseProcesses          = $ADTSession.AppProcessesToClose
                    CloseProcessesCountdown = $PostDeadlineCloseCountdownSeconds
                    CheckDiskSpace          = $true
                    PromptToSave            = $true
                    PersistPrompt           = $true
                    WindowLocation          = 'Center'
                    Title                   = $ActionTitle
                    Subtitle                = $ProcessCloseSubtitle
                }

                Show-ADTInstallationWelcome @FinalWelcomeParams

                $FinalEnforcementDisplayed = $true
                $ProceedWithDeployment = $true

                continue
            }

            ##================================================
            ## MARK: Build Process Description
            ##================================================

            $ProcessDescriptions = @(
                $ADTSession.AppProcessesToClose |
                    ForEach-Object {
                        if ($_.Description)
                        {
                            $_.Description
                        }
                        elseif ($_.Name)
                        {
                            $_.Name
                        }
                    }
            ) -join ', '

            if ([string]::IsNullOrWhiteSpace($ProcessDescriptions))
            {
                $ProcessDescriptions = $ADTSession.AppName
            }

            ##================================================
            ## MARK: Initial Prompt
            ##================================================

            if (-not $InitialDeferralUsed)
            {
                $TwoHourReminder = $CurrentTime.AddHours(
                    $InitialTwoHourDeferHours
                )

                $FourHourReminder = $CurrentTime.AddHours(
                    $InitialFourHourDeferHours
                )

                if ($TwoHourReminder -gt $DeferDeadline)
                {
                    $TwoHourReminder = $DeferDeadline
                }

                if ($FourHourReminder -gt $DeferDeadline)
                {
                    $FourHourReminder = $DeferDeadline
                }

                $Message = @"
Please save your work before continuing.

APPLICATIONS THAT WILL BE CLOSED
$ProcessDescriptions

FINAL $($DeploymentAction.ToUpper()) DEADLINE
$($DeferDeadline.ToString('dddd, MMMM dd, yyyy h:mm tt'))

$InitialActionMessage

"@

                $PromptParams = @{
                    Title            = $ActionTitle
                    Subtitle         = "Moody's - App $DeploymentAction`: Reboot not required"
                    Message          = $Message
                    ButtonLeftText   = $ActionNowButtonText
                    ButtonMiddleText = $TwoHourButtonText
                    ButtonRightText  = $FourHourButtonText
                    WindowLocation   = 'Center'
                    PersistPrompt    = $true
                    NoExitOnTimeout  = $true
                }

                $UserSelection = Show-ADTInstallationPrompt @PromptParams

                switch ($UserSelection)
                {
                    $ActionNowButtonText
                    {
                        Write-ADTLogEntry -Message "The user selected [$ActionNowButtonText]."

                        $ProceedWithDeployment = $true
                    }

                    $TwoHourButtonText
                    {
                        $DeferralStartTime = Get-Date

                        $SelectedInterval = New-TimeSpan `
                            -Hours $InitialTwoHourDeferHours

                        $NextPromptTime = $DeferralStartTime.Add(
                            $SelectedInterval
                        )

                        if ($NextPromptTime -gt $DeferDeadline)
                        {
                            $NextPromptTime = $DeferDeadline
                            $SelectedInterval = $NextPromptTime - $DeferralStartTime
                        }

                        if ($SelectedInterval.TotalSeconds -gt 0)
                        {
                            Set-ADTDeferHistory `
                                -DeferDeadline $DeferDeadline `
                                -DeferRunInterval $SelectedInterval `
                                -DeferRunIntervalLastTime $DeferralStartTime

                            $InitialDeferralUsed = $true

                            Write-ADTLogEntry -Message "The user selected the two-hour [$ActionDescription] deferral. The next prompt is scheduled for [$NextPromptTime]."
                        }
                        else
                        {
                            $NextPromptTime = $DeferDeadline

                            Write-ADTLogEntry -Message 'No deferral time remains. Proceeding to final enforcement.'
                        }
                    }

                    $FourHourButtonText
                    {
                        $DeferralStartTime = Get-Date

                        $SelectedInterval = New-TimeSpan `
                            -Hours $InitialFourHourDeferHours

                        $NextPromptTime = $DeferralStartTime.Add(
                            $SelectedInterval
                        )

                        if ($NextPromptTime -gt $DeferDeadline)
                        {
                            $NextPromptTime = $DeferDeadline
                            $SelectedInterval = $NextPromptTime - $DeferralStartTime
                        }

                        if ($SelectedInterval.TotalSeconds -gt 0)
                        {
                            Set-ADTDeferHistory `
                                -DeferDeadline $DeferDeadline `
                                -DeferRunInterval $SelectedInterval `
                                -DeferRunIntervalLastTime $DeferralStartTime

                            $InitialDeferralUsed = $true

                            Write-ADTLogEntry -Message "The user selected the four-hour [$ActionDescription] deferral. The next prompt is scheduled for [$NextPromptTime]."
                        }
                        else
                        {
                            $NextPromptTime = $DeferDeadline

                            Write-ADTLogEntry -Message 'No deferral time remains. Proceeding to final enforcement.'
                        }
                    }

                    default
                    {
                        if (
                            [string]$ADTSession.DeployMode -in
                            @('Silent', 'NonInteractive')
                        )
                        {
                            Write-ADTLogEntry `
                                -Message "The initial prompt was bypassed because the deployment entered [$($ADTSession.DeployMode)] mode. Continuing without deferral." 
                                

                            $ProceedWithDeployment = $true
                        }
                        else
                        {
                            Write-ADTLogEntry `
                                -Message "The initial prompt returned an unexpected result [$UserSelection]. The prompt will be displayed again after 60 seconds." 
                                
                            Start-Sleep -Seconds 60
                        }
                    }
                }

                continue
            }

            ##================================================
            ## MARK: Subsequent Prompt
            ##================================================

            $NextTwoHourReminder = $CurrentTime.AddHours(
                $SubsequentDeferHours
            )

            if ($NextTwoHourReminder -gt $DeferDeadline)
            {
                $NextTwoHourReminder = $DeferDeadline
            }

            $Message = @"
Please save your work before continuing.

APPLICATIONS THAT WILL BE CLOSED
$ProcessDescriptions

FINAL $($DeploymentAction.ToUpper()) DEADLINE
$($DeferDeadline.ToString('dddd, MMMM dd, yyyy h:mm tt'))

$SubsequentActionMessage

"@

            $PromptParams = @{
                Title           = $ActionTitle
                Subtitle        = "Moody's - App $DeploymentAction`: Reboot not required"
                Message         = $Message
                ButtonLeftText  = $ActionNowButtonText
                ButtonRightText = $TwoHourButtonText
                WindowLocation  = 'Center'
                PersistPrompt   = $true
                NoExitOnTimeout = $true
            }

            $UserSelection = Show-ADTInstallationPrompt @PromptParams

            switch ($UserSelection)
            {
                $ActionNowButtonText
                {
                    Write-ADTLogEntry -Message "The user selected [$ActionNowButtonText]."

                    $ProceedWithDeployment = $true
                }

                $TwoHourButtonText
                {
                    $DeferralStartTime = Get-Date

                    $SelectedInterval = New-TimeSpan `
                        -Hours $SubsequentDeferHours

                    $NextPromptTime = $DeferralStartTime.Add(
                        $SelectedInterval
                    )

                    if ($NextPromptTime -gt $DeferDeadline)
                    {
                        $NextPromptTime = $DeferDeadline
                        $SelectedInterval = $NextPromptTime - $DeferralStartTime
                    }

                    if ($SelectedInterval.TotalSeconds -gt 0)
                    {
                        Set-ADTDeferHistory `
                            -DeferDeadline $DeferDeadline `
                            -DeferRunInterval $SelectedInterval `
                            -DeferRunIntervalLastTime $DeferralStartTime

                        Write-ADTLogEntry -Message "The user selected another two-hour [$ActionDescription] deferral. The next prompt is scheduled for [$NextPromptTime]."
                    }
                    else
                    {
                        $NextPromptTime = $DeferDeadline

                        Write-ADTLogEntry -Message 'No deferral time remains. Proceeding to final enforcement.'
                    }
                }

                default
                {
                    if (
                        [string]$ADTSession.DeployMode -in
                        @('Silent', 'NonInteractive')
                    )
                    {
                        Write-ADTLogEntry `
                            -Message "The subsequent prompt was bypassed because the deployment entered [$($ADTSession.DeployMode)] mode. Continuing without deferral." 
                            
                        $ProceedWithDeployment = $true
                    }
                    else
                    {
                        Write-ADTLogEntry `
                            -Message "The subsequent prompt returned an unexpected result [$UserSelection]. The prompt will be displayed again after 60 seconds." 
                            
                        Start-Sleep -Seconds 60
                    }
                }
            }
        }

        
        ##================================================
        ## MARK: Silent Application Closure before Deployment
        ##================================================

        if (-not $FinalEnforcementDisplayed)
        {
            if (
                $ADTSession.AppProcessesToClose -and
                $ADTSession.AppProcessesToClose.Count -gt 0
            )
            {
                $RunningProcessesBeforeClosure = @(
                    Get-ADTRunningProcesses `
                        -ProcessObjects $ADTSession.AppProcessesToClose
                )

                if ($RunningProcessesBeforeClosure.Count -gt 0)
                {
                    $RunningProcessNames = @(
                        $RunningProcessesBeforeClosure |
                            ForEach-Object { $_.Name } |
                            Sort-Object -Unique
                    ) -join ', '

                    Write-ADTLogEntry -Message "The user selected [$ActionNowButtonText]. Silently closing configured process(es): [$RunningProcessNames]."

                    $SilentCloseParams = @{
                        CloseProcesses = $ADTSession.AppProcessesToClose
                        Silent         = $true
                        Title          = $ActionTitle
                        Subtitle       = $ProcessCloseSubtitle
                    }

                    Show-ADTInstallationWelcome @SilentCloseParams

                    Write-ADTLogEntry -Message "Configured process closure completed successfully. Continuing with the [$ActionDescription]."
                }
                else
                {
                    Write-ADTLogEntry -Message "The user selected [$ActionNowButtonText]. None of the configured impacted processes are currently running. Continuing with the [$ActionDescription]."
                }
            }
            else
            {
                Write-ADTLogEntry -Message "The user selected [$ActionNowButtonText]. No processes are configured in AppProcessesToClose. Continuing with the [$ActionDescription]."
            }
        }
    }
    catch
    {
        $ErrorMessage = "The managed [$ActionDescription] deferral workflow failed. Error: $($_.Exception.Message)"

        Write-ADTLogEntry `
            -Message $ErrorMessage 
   
        throw
    }
}

##*===============================================
##* MARK: SCRIPT BODY
##*===============================================

# Announce successful importation of module.
Write-ADTLogEntry -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ScriptSection Initialization
