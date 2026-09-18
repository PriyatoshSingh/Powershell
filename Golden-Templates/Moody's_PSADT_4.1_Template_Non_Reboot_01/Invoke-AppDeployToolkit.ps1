<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeployMode Silent

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

.NOTES
Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1, and Invoke-AppDeployToolkit.exe
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

# Zero-Config MSI support is provided when "AppName" is null or empty.
# By setting the "AppName" property, Zero-Config MSI will be disabled.
$adtSession = @{
    # App variables.
    AppVendor = 'VendorName'
    AppName = 'AppName'
    AppVersion = 'Version'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = 'ReleaseVersion'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @(@{ Name = 'ProcessName1'; Description = 'Application' }, @{ Name = 'ProcessName2'; Description = 'Application' })
    AppScriptVersion = '1.0.0'
    AppScriptDate = 'YYYY-MM-DD'
    AppScriptAuthor = 'Packager Name'
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = 'VendorName_AppName_Version_ReleaseVersion'
    InstallTitle = "Moody's"

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

    #Variables: Environment Variables
	[string]$sProgramData = $Env:ProgramData
	[string]$sPF = $Env:ProgramFiles
	[string]$sPF86 = ${Env:ProgramFiles(x86)}
	[string]$sWindir = $Env:windir
	[string]$sSysdrv = $Env:SystemDrive
    [string]$sPublic = $Env:PUBLIC
    $OSVersion = (Get-CimInstance Win32_OperatingSystem).Version
    $LoggedOnUser = (Get-ADTLoggedOnUser)

	
	#MSI or EXE PROPERTY/ARP Variables
	[string]$sProductVersion = 'version info'
	[string]$sProductName = 'AppName'

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## Moody's block hours logic.
    ## Remove this section if blocked hours are not required for the application.
    $blockedHours = @(8, 9, 10, 11, 12, 13)
    while (((Get-Date).DayOfWeek -eq 'Monday') -and ((Get-Date).Hour -in $blockedHours))
    {
        Write-ADTLogEntry -Message 'Deployment is paused during the Monday blocked-hours window.'
        Start-Sleep -Seconds 1800
    }

    ## Determine whether the same or a newer version is already installed.
     $installedApp = Get-ADTApplication -Name $adtSession.AppName -NameMatch Exact -FilterScript {[version]$_.DisplayVersion -ge [version]$adtSession.AppVersion} -ErrorAction SilentlyContinue

    if ($installedApp)
    {
        Write-ADTLogEntry -Message "The same or a newer version of [$($adtSession.AppName)] is already installed."
        Close-ADTSession -ExitCode 0
        return
    }

    ##Check if the script is running from the same path and exit with 400

    $CurrentPackagePath = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    try
    {
        $MatchingPackageInstances = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Invoke-AppDeployToolkit.exe'" -ErrorAction Stop | Where-Object {
            if ([string]::IsNullOrWhiteSpace($_.ExecutablePath))
            {
                return $false
            }

            $RunningPackagePath = [System.IO.Path]::GetDirectoryName($_.ExecutablePath).TrimEnd('\')

            Write-ADTLogEntry -Message "Invoke-AppDeployToolkit.exe process ID [$($_.ProcessId)] is running from [$RunningPackagePath]."

            $RunningPackagePath -ieq $CurrentPackagePath
        })

        Write-ADTLogEntry -Message "Current package directory is [$CurrentPackagePath]."
        Write-ADTLogEntry -Message "Found [$($MatchingPackageInstances.Count)] instance(s) running from the current package directory."

        if ($MatchingPackageInstances.Count -gt 1)
        {
            $MatchingProcessIds = $MatchingPackageInstances.ProcessId -join ', '

            Write-ADTLogEntry -Message "Another instance of Invoke-AppDeployToolkit.exe is already running from [$CurrentPackagePath]. Matching process IDs: [$MatchingProcessIds]. Exiting with code [400]."

            Close-ADTSession -ExitCode 400
            return
        }

        Write-ADTLogEntry -Message "No duplicate instance was detected for [$CurrentPackagePath]. Continuing with the deployment."
    }
    catch
    {
        Write-ADTLogEntry -Message "The duplicate-instance check could not be completed. Error: $($_.Exception.Message)"
    
    }

    ##================================================
    ## MARK: Managed Deferral
    ##================================================

        $ManagedDeferralParams = @{
            ADTSession                              = $adtSession
            DeferDeadlineHours                      = 8
            InitialTwoHourDeferHours                = 2
            InitialFourHourDeferHours               = 4
            SubsequentDeferHours                    = 2
            PostDeadlineCloseCountdownSeconds       = 1800
            DeferralSleepCheckSeconds               = 300
        }

        Invoke-MDYManagedDeferral @ManagedDeferralParams

        Show-ADTInstallationProgress -StatusMessage 'Please wait while the application is installed.' -WindowLocation Center -Subtitle "Moody's - App Installation"

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI installations.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
        if ($adtSession.DefaultMspFiles)
        {
            $adtSession.DefaultMspFiles | Start-ADTMsiProcess -Action Patch
        }
    }

    #EXE Installation
    ## Replace APPName.exe and its arguments for each application package.
    $installerPath = "$($adtSession.DirFiles)\APPName.exe"
    if (!(Test-Path -LiteralPath $installerPath -PathType Leaf))
    {
        Write-ADTLogEntry -Message "Installer file was not found: [$installerPath]." -Severity 3
        Close-ADTSession -ExitCode 69002
        return
    }

    $installResult = Start-ADTProcess -FilePath $installerPath -ArgumentList '/S' -PassThru
    if ($installResult.ExitCode -notin $adtSession.AppSuccessExitCodes -and $installResult.ExitCode -notin $adtSession.AppRebootExitCodes)
    {
        Write-ADTLogEntry -Message "Installation failed with exit code [$($installResult.ExitCode)]."
        Close-ADTSession -ExitCode $installResult.ExitCode
        return
    }


    Write-ADTLogEntry -Message "Successfully installed [$($adtSession.AppName) $($adtSession.AppVersion)]."

    
    #MSI/MST Installation
    $adtSession.InstallPhase = $adtSession.DeploymentType
    $msiPath = "$($adtSession.DirFiles)\AppName.msi"
    $mstPath = "$($adtSession.DirFiles)AppName.Mst"
    if (!(Test-Path -LiteralPath $msiPath -PathType Leaf))
    {
        Write-ADTLogEntry -Message "Chrome MSI not found at [$msiPath]."
        Close-ADTSession -ExitCode 69002
        return
    }

    $msiParams = @{ Action='Install'; FilePath=$msiPath; ArgumentList='/qn REBOOTPROMPT=S REBOOT=ReallySuppress ALLUSERS=1 MSIRESTARTMANAGERCONTROL=Disable'; PassThru=$true }
    if (Test-Path -LiteralPath $mstPath -PathType Leaf) { $msiParams.Transforms = $mstPath }
    else { Write-ADTLogEntry -Message "MST not found at [$mstPath]. Continuing without it."}

    $result = Start-ADTMsiProcess @msiParams
    if ($result.ExitCode -notin $adtSession.AppSuccessExitCodes -and $result.ExitCode -notin $adtSession.AppRebootExitCodes)
    {
        Close-ADTSession -ExitCode $result.ExitCode
        return
    }

    ##================================================
    ## MARK: Post Install
    ##================================================
  
      $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

       # Add application-specific post-installation tasks here.


        #Create Folder
        New-ADTFolder -Path $appFolder
        Write-ADTLogEntry -Message "Created or verified application folder [$appFolder]."


    
        #Copy a Single File
        $sourceFile = "$($adtSession.DirFiles)\config.xml"

        if (Test-Path -LiteralPath $sourceFile -PathType Leaf)
        {
            Copy-ADTFile -Path $sourceFile -Destination $appFolder

            Write-ADTLogEntry -Message "Copied [$sourceFile] to [$appFolder]."
        }
        else
        {
            Write-ADTLogEntry -Message "Source file was not found: [$sourceFile]." 
        }


        #Copy Multiple Files
        $sourceFolder = "$($adtSession.DirFiles)\Configuration"

        if (Test-Path -LiteralPath $sourceFolder -PathType Container)
        {
            Copy-ADTFile -Path "$sourceFolder\*" -Destination $appFolder

            Write-ADTLogEntry -Message "Copied the contents of [$sourceFolder] to [$appFolder]."
        }
        else
        {
            Write-ADTLogEntry -Message "Source folder was not found: [$sourceFolder]."
        }


   
        #Delete a File
        if (Test-Path -LiteralPath $configFile -PathType Leaf)
        {
            Remove-ADTFile -Path $configFile

            Write-ADTLogEntry -Message "Removed file [$configFile]."
        }


     
         #Delete Multiple Files
        Remove-ADTFile -Path "$appFolder\*.log"

        Write-ADTLogEntry -Message "Removed log files from [$appFolder]."

        
        #Delete a Folder
        $oldFolder = Join-Path -Path $env:ProgramFiles -ChildPath 'VendorName\AppName\OldVersion'

        if (Test-Path -LiteralPath $oldFolder -PathType Container)
        {
            Remove-ADTFolder -Path $oldFolder

            Write-ADTLogEntry -Message "Removed folder [$oldFolder]."
        }


      
        #Create Registry Key
        Set-ADTRegistryKey -LiteralPath $registryPath

        Write-ADTLogEntry -Message "Created or verified registry key [$registryPath]."


        #Set String Registry Value
        Set-ADTRegistryKey -LiteralPath $registryPath -Name 'ProductVersion' -Value $adtSession.AppVersion -Type String
        Write-ADTLogEntry -Message "Set ProductVersion to [$($adtSession.AppVersion)] under [$registryPath]."


        
        #Set DWORD Registry Value
       

        Set-ADTRegistryKey -LiteralPath $registryPath -Name 'Installed' -Value 1 -Type DWord
        Write-ADTLogEntry -Message "Set Installed DWORD value to [1] under [$registryPath]."


       #Create Start Menu Shortcut
       $targetPath = Join-Path -Path $appFolder -ChildPath 'AppName.exe'

        if (Test-Path -LiteralPath $targetPath -PathType Leaf)
        {
            New-ADTShortcut -Path $shortcutPath -TargetPath $targetPath -WorkingDirectory $appFolder -Description 'AppName'
            Write-ADTLogEntry -Message "Created shortcut [$shortcutPath]."
        }


       #Perform Action for Every User Profile
        foreach ($userProfile in (Get-ADTUserProfiles))
        {
            $profilePath = $userProfile.ProfilePath
            $userFile = Join-Path -Path $profilePath -ChildPath 'AppData\Local\VendorName\AppName\config.xml'

            if (Test-Path -LiteralPath $userFile -PathType Leaf)
            {
                Remove-ADTFile -Path $userFile

                Write-ADTLogEntry -Message "Removed file from user profile: [$userFile]."
            }
        }



        
        #Start Application as Logged-On User
        $applicationPath = Join-Path -Path $appFolder -ChildPath 'AppName.exe'

        if (Test-Path -LiteralPath $applicationPath -PathType Leaf)
        {
            Start-ADTProcessAsUser -Path $applicationPath -NoWait

            Write-ADTLogEntry -Message "Started [$applicationPath] as the logged-on user."
        }



       
        #Create Custom Detection Registry
        $detectionRegistryPath = "HKLM:\SOFTWARE\CustomPKG\$($adtSession.AppVendor)$($adtSession.AppName)_$($adtSession.AppVersion)"

        Set-ADTRegistryKey -LiteralPath $detectionRegistryPath -Name 'ProductVersion' -Value $adtSession.AppVersion -Type String
        Write-ADTLogEntry -Message "Created detection registry key [$detectionRegistryPath]."
       

    
  }
function Uninstall-ADTDeployment
{
        [CmdletBinding()]
        param
        (
        )

   
        ## MARK: Pre-Uninstall
   
        $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    
        ## Check Whether Application is Installed
   
            $installedApp = Get-ADTApplication -Name $adtSession.AppName -NameMatch Exact -FilterScript {[version]$_.DisplayVersion -eq [version]$adtSession.AppVersion} -ErrorAction SilentlyContinue

        if ($installedApp)
        {
            Write-ADTLogEntry -Message "Found [$($installedApplication.DisplayName)] version [$($installedApplication.DisplayVersion)]."
        }

    
        ##================================================
        ## MARK: Managed Deferral
        ##================================================
   
        $ManagedDeferralParams = @{
        ADTSession                        = $adtSession
        DeferDeadlineHours                = 8
        InitialTwoHourDeferHours          = 2
        InitialFourHourDeferHours         = 4
        SubsequentDeferHours              = 2
        PostDeadlineCloseCountdownSeconds = 1800
        DeferralSleepCheckSeconds         = 300
    }

        Invoke-MDYManagedDeferral @ManagedDeferralParams

        Show-ADTInstallationProgress -StatusMessage 'Please wait while the application is uninstalled.' -WindowLocation Center -Subtitle "Moody's - App Uninstallation"

        


        
        ##================================================
        ## MARK: Uninstall
        ##================================================
       
        $adtSession.InstallPhase = $adtSession.DeploymentType


    
        #Zero-Config MSI Uninstallation
        ## Retain only when Zero-Config MSI is used
    
        if ($adtSession.UseDefaultMsi)
        {
            $executeDefaultMsiParams = @{
                Action   = 'Uninstall'
                FilePath = $adtSession.DefaultMsiFile
            }

            $uninstallResult = Start-ADTMsiProcess @executeDefaultMsiParams -PassThru

            if ($uninstallResult.ExitCode -notin $adtSession.AppSuccessExitCodes -and $uninstallResult.ExitCode -notin $adtSession.AppRebootExitCodes)
            {
                Write-ADTLogEntry -Message "Zero-Config MSI uninstallation failed with exit code [$($uninstallResult.ExitCode)]."
                Close-ADTSession -ExitCode $uninstallResult.ExitCode
                return
            }

            Write-ADTLogEntry -Message "Successfully completed the Zero-Config MSI uninstallation."
        }


        #EXE Uninstallation
        ## Retain only for EXE-based applications
   
    
        $uninstallerPath = "$env:ProgramFiles\VendorName\AppName\Uninstall.exe"

        if (Test-Path -LiteralPath $uninstallerPath -PathType Leaf)
        {
            Write-ADTLogEntry -Message "Starting EXE uninstallation using [$uninstallerPath]."

            $uninstallResult = Start-ADTProcess -FilePath $uninstallerPath -ArgumentList '/S' -PassThru

            if ($uninstallResult.ExitCode -notin $adtSession.AppSuccessExitCodes -and $uninstallResult.ExitCode -notin $adtSession.AppRebootExitCodes)
            {
                Write-ADTLogEntry -Message "EXE uninstallation failed with exit code [$($uninstallResult.ExitCode)]."
                Close-ADTSession -ExitCode $uninstallResult.ExitCode
                return
            }

            Write-ADTLogEntry -Message "Successfully completed the EXE uninstallation for [$($adtSession.AppName)]."
        }
        else
        {
            Write-ADTLogEntry -Message "EXE uninstaller was not found at [$uninstallerPath]."
            Close-ADTSession -ExitCode 69002
            return
        }
    


        #MSI Uninstallation by Product Code
        ## Retain only for MSI-based applications
   

        $productCode = '{00000000-0000-0000-0000-000000000000}'
        $installedMsi = Get-ADTApplication -ProductCode $productCode -ErrorAction SilentlyContinue

        if ($installedMsi)
        {
            Write-ADTLogEntry -Message "Uninstalling [$($installedMsi.DisplayName)] version [$($installedMsi.DisplayVersion)] using product code [$productCode]."

            $uninstallResult = Start-ADTMsiProcess -Action Uninstall -ProductCode $productCode -ArgumentList 'REBOOT=ReallySuppress' -PassThru

            if ($uninstallResult.ExitCode -notin $adtSession.AppSuccessExitCodes -and $uninstallResult.ExitCode -notin $adtSession.AppRebootExitCodes)
            {
                Write-ADTLogEntry -Message "MSI uninstallation failed with exit code [$($uninstallResult.ExitCode)]."
                Close-ADTSession -ExitCode $uninstallResult.ExitCode
                return
            }

            Write-ADTLogEntry -Message "Successfully uninstalled MSI product [$productCode]."
        }
        else
        {
            Write-ADTLogEntry -Message "MSI product [$productCode] is not installed. MSI uninstallation is not required."
        }
    


        #MSI Uninstallation Using MSI Source
        ## Retain when the original MSI is available
   

    
        $msiPath = "$($adtSession.DirFiles)\Application.msi"

        if (Test-Path -LiteralPath $msiPath -PathType Leaf)
        {
            Write-ADTLogEntry -Message "Starting MSI uninstallation using [$msiPath]."

            $uninstallResult = Start-ADTMsiProcess -Action Uninstall -FilePath $msiPath -ArgumentList 'REBOOT=ReallySuppress' -PassThru

            if ($uninstallResult.ExitCode -notin $adtSession.AppSuccessExitCodes -and $uninstallResult.ExitCode -notin $adtSession.AppRebootExitCodes)
            {
                Write-ADTLogEntry -Message "MSI uninstallation failed with exit code [$($uninstallResult.ExitCode)]."
                Close-ADTSession -ExitCode $uninstallResult.ExitCode
                return
            }

            Write-ADTLogEntry -Message "Successfully completed the MSI uninstallation."
        }
        else
        {
            Write-ADTLogEntry -Message "MSI source file was not found at [$msiPath]."
            Close-ADTSession -ExitCode 69002
            return
        }
    


    
        # Uninstall Multiple MSI Versions
        ## Use when MSI product codes change between releases
   

        $installedApplications = Get-ADTApplication -Name $adtSession.AppName -NameMatch Exact -ApplicationType MSI -ErrorAction SilentlyContinue

        foreach ($application in $installedApplications)
        {
            if ($application.ProductCode)
            {
                Write-ADTLogEntry -Message "Uninstalling [$($application.DisplayName)] version [$($application.DisplayVersion)] with product code [$($application.ProductCode)]."

                $uninstallResult = Start-ADTMsiProcess -Action Uninstall -ProductCode $application.ProductCode -ArgumentList 'REBOOT=ReallySuppress' -PassThru

                if ($uninstallResult.ExitCode -notin $adtSession.AppSuccessExitCodes -and $uninstallResult.ExitCode -notin $adtSession.AppRebootExitCodes)
                {
                    Write-ADTLogEntry -Message "Failed to uninstall product [$($application.ProductCode)] with exit code [$($uninstallResult.ExitCode)]."
                    Close-ADTSession -ExitCode $uninstallResult.ExitCode
                    return
                }

                Write-ADTLogEntry -Message "Successfully uninstalled product [$($application.ProductCode)]."
            }
        }
    


    
        ##================================================
        ## MARK: Post uninstall
        ##================================================
   

        $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"


    
        ## Delete Individual File

        $configFile = "$env:ProgramFiles\VendorName\AppName\config.xml"

        if (Test-Path -LiteralPath $configFile -PathType Leaf)
        {
            Remove-ADTFile -Path $configFile
            Write-ADTLogEntry -Message "Removed file [$configFile]."
        }
        else
        {
            Write-ADTLogEntry -Message "File [$configFile] was not found. File removal is not required."
        }


    
        ## Delete Multiple Files
   
        $applicationFolder = "$env:ProgramFiles\VendorName\AppName"

        if (Test-Path -LiteralPath $applicationFolder -PathType Container)
        {
            Remove-ADTFile -Path "$applicationFolder\*.log"
            Remove-ADTFile -Path "$applicationFolder\*.tmp"
            Write-ADTLogEntry -Message "Removed LOG and TMP files from [$applicationFolder]."
        }


  
        ## Delete Application Folder
   
        if (Test-Path -LiteralPath $applicationFolder -PathType Container)
        {
            try
            {
                Remove-ADTFolder -Path $applicationFolder
                Write-ADTLogEntry -Message "Successfully removed application folder [$applicationFolder]."
            }
            catch
            {
                Write-ADTLogEntry -Message "Failed to remove application folder [$applicationFolder]. Error: $($_.Exception.Message)"
            }
        }
        else
        {
            Write-ADTLogEntry -Message "Application folder [$applicationFolder] was not found. Folder removal is not required."
        }


 
        ## Delete Start Menu Shortcut
  
        $startMenuShortcut = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AppName.lnk"

        if (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)
        {
            Remove-ADTFile -Path $startMenuShortcut
            Write-ADTLogEntry -Message "Removed Start Menu shortcut [$startMenuShortcut]."
        }


   
        ## Delete Public Desktop Shortcut
   
        $publicDesktopShortcut = "$env:Public\Desktop\AppName.lnk"

        if (Test-Path -LiteralPath $publicDesktopShortcut -PathType Leaf)
        {
            Remove-ADTFile -Path $publicDesktopShortcut
            Write-ADTLogEntry -Message "Removed public desktop shortcut [$publicDesktopShortcut]."
        }


   
        ## Delete Registry Value
   
        $registryPath = 'HKLM:\SOFTWARE\VendorName\AppName'

        if (Test-Path -LiteralPath $registryPath)
        {
            Remove-ADTRegistryKey -LiteralPath $registryPath -Name 'ProductVersion'
            Write-ADTLogEntry -Message "Removed ProductVersion registry value from [$registryPath]."
        }


 
        ## Delete Registry Key
    
        if (Test-Path -LiteralPath $registryPath)
        {
            Remove-ADTRegistryKey -LiteralPath $registryPath -Recurse
            Write-ADTLogEntry -Message "Removed registry key [$registryPath]."
        }
        else
        {
            Write-ADTLogEntry -Message "Registry key [$registryPath] was not found. Registry cleanup is not required."
        }


   
        ## Remove Files and Folders from User Profiles
    
        foreach ($userProfile in (Get-ADTUserProfiles))
        {
            $profilePath = $userProfile.ProfilePath
            $userApplicationFolder = "$profilePath\AppData\Local\VendorName\AppName"
            $userConfigFile = "$userApplicationFolder\config.xml"
            $userShortcut = "$profilePath\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\AppName.lnk"

            if (Test-Path -LiteralPath $userConfigFile -PathType Leaf)
            {
                Remove-ADTFile -Path $userConfigFile
                Write-ADTLogEntry -Message "Removed user configuration file [$userConfigFile]."
            }

            if (Test-Path -LiteralPath $userShortcut -PathType Leaf)
            {
                Remove-ADTFile -Path $userShortcut
                Write-ADTLogEntry -Message "Removed user Start Menu shortcut [$userShortcut]."
            }

            if (Test-Path -LiteralPath $userApplicationFolder -PathType Container)
            {
                try
                {
                    Remove-ADTFolder -Path $userApplicationFolder
                    Write-ADTLogEntry -Message "Removed application folder from user profile [$userApplicationFolder]."
                }
                catch
                {
                    Write-ADTLogEntry -Message "Failed to remove application folder from user profile [$userApplicationFolder]. Error: $($_.Exception.Message)"
                }
            }
        }


    
        ## Alternative: Remove File from All User Profiles
        ## Do not use if equivalent cleanup is already performed above
   
        Remove-ADTFileFromUserProfiles -Path 'AppData\Local\VendorName\AppName\config.xml'
        Write-ADTLogEntry -Message "Removed config.xml from all available user profiles."
    


   
        ## Remove Custom Detection Registry
    
        $detectionRegistryPath = "HKLM:\SOFTWARE\CustomPKG\$($adtSession.AppVendor)$($adtSession.AppName)_$($adtSession.AppVersion)"

        if (Test-Path -LiteralPath $detectionRegistryPath)
        {
            Remove-ADTRegistryKey -LiteralPath $detectionRegistryPath -Recurse
            Write-ADTLogEntry -Message "Removed custom detection registry key [$detectionRegistryPath]."
        }
        else
        {
            Write-ADTLogEntry -Message "Custom detection registry key [$detectionRegistryPath] was not found."
        }


   
        ## Remove PSADT Defer History
   
        $installName = '{0}_{1}_{2}_{3}' -f $adtSession.AppVendor.Trim(), $adtSession.AppName, $adtSession.AppVersion, $adtSession.AppRevision
        $deferHistoryName = (($installName -replace '\s', '').Trim('_') -replace '_+', '_')
        $deferHistoryPath = "HKLM:\SOFTWARE\PSAppDeployToolkit\DeferHistory\$deferHistoryName"

        if (Test-Path -LiteralPath $deferHistoryPath)
        {
            Remove-ADTRegistryKey -LiteralPath $deferHistoryPath -Recurse
            Write-ADTLogEntry -Message "Removed PSADT defer-history key [$deferHistoryPath]."
        }


   
        ## Verify Uninstallation
    
        $remainingApplication = Get-ADTApplication -Name $adtSession.AppName -NameMatch Exact -ErrorAction SilentlyContinue

        if ($remainingApplication)
        {
            Write-ADTLogEntry -Message "The application is still detected after uninstallation. Detected version: [$($remainingApplication.DisplayVersion)]."
        }
        else
        {
            Write-ADTLogEntry -Message "The application is no longer detected. Uninstallation completed successfully."
        }

    }
function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    Show-ADTInstallationProgress -StatusMessage 'Please wait while the application is repaired.'

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Add application-specific repair commands here.

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## Add application-specific post-repair tasks here.
}

##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -Icon Error -NoWait

    Close-ADTSession -ExitCode 60001
}

