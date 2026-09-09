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
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-08-06'
    AppScriptAuthor = 'Packager Name'
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
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


    ## Determine whether the same or a newer version is already installed.
     $installedApp = Get-ADTApplication -Name $adtSession.AppName -NameMatch Exact -FilterScript {[version]$_.DisplayVersion -ge [version]$adtSession.AppVersion} -ErrorAction SilentlyContinue

    if ($installedApp)
    {
        Write-ADTLogEntry -Message "The same or a newer version of [$($adtSession.AppName)] is already installed."
        Close-ADTSession -ExitCode 0
        return
    }

   

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
    ## MARK: Post-Install
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


              
        #Create Custom Detection Registry
        $detectionRegistryPath = "HKLM:\SOFTWARE\CustomPKG\$($adtSession.AppVendor)$($adtSession.AppName)_$($adtSession.AppVersion)"

        Set-ADTRegistryKey -LiteralPath $detectionRegistryPath -Name 'ProductVersion' -Value $adtSession.AppVersion -Type String
        Write-ADTLogEntry -Message "Created detection registry key [$detectionRegistryPath]."
       

    
  }
function Uninstall-ADTDeployment
{
            

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

