# Microsoft Graph module setup for Windows PowerShell 5.1
# Installs modules outside the OneDrive Documents path.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#-----------------------------------------------------------
# Configuration
#-----------------------------------------------------------

$GraphVersion = '2.25.0'
$CustomModulePath = Join-Path $HOME 'PowerShellModules'

$GraphModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Groups'
    'Microsoft.Graph.Identity.DirectoryManagement'
)

Write-Host ''
Write-Host 'Microsoft Graph Setup for Windows PowerShell 5.1' `
    -ForegroundColor Cyan

Write-Host '------------------------------------------------' `
    -ForegroundColor Cyan

Write-Host "PowerShell version : $($PSVersionTable.PSVersion)"
Write-Host "PowerShell edition : $($PSVersionTable.PSEdition)"
Write-Host "Graph version      : $GraphVersion"
Write-Host "Custom module path : $CustomModulePath"
Write-Host ''

#-----------------------------------------------------------
# Confirm Windows PowerShell 5.1
#-----------------------------------------------------------

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Warning 'This setup script is intended for Windows PowerShell 5.1.'
}

#-----------------------------------------------------------
# Check that no Graph assemblies are already loaded
#-----------------------------------------------------------

$LoadedGraphAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object {
        $_.FullName -like 'Microsoft.Graph*'
    }

if ($LoadedGraphAssemblies) {
    Write-Warning 'Microsoft Graph assemblies are already loaded in this process.'
    Write-Warning 'Close this PowerShell window and run the script in a fresh PowerShell 5.1 process.'

    $LoadedGraphAssemblies |
        Select-Object FullName, Location |
        Format-Table -AutoSize

    exit 1
}

#-----------------------------------------------------------
# Create the custom module directory
#-----------------------------------------------------------

if (-not (Test-Path -LiteralPath $CustomModulePath)) {
    New-Item `
        -Path $CustomModulePath `
        -ItemType Directory `
        -Force |
        Out-Null

    Write-Host 'Created custom module directory.' `
        -ForegroundColor Green
}
else {
    Write-Host 'Custom module directory already exists.' `
        -ForegroundColor Green
}

#-----------------------------------------------------------
# Add the path to the current process
#-----------------------------------------------------------

$SessionModulePaths = $env:PSModulePath -split ';'

if ($SessionModulePaths -notcontains $CustomModulePath) {
    $env:PSModulePath = "$CustomModulePath;$env:PSModulePath"

    Write-Host 'Added the custom path to the current process.' `
        -ForegroundColor Green
}
else {
    Write-Host 'Custom path already exists in the current process.' `
        -ForegroundColor Green
}

#-----------------------------------------------------------
# Add the path permanently for the current user
#-----------------------------------------------------------

$UserModulePath = [System.Environment]::GetEnvironmentVariable(
    'PSModulePath',
    [System.EnvironmentVariableTarget]::User
)

$UserModulePaths = @(
    $UserModulePath -split ';' |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
)

if ($UserModulePaths -notcontains $CustomModulePath) {
    if ([string]::IsNullOrWhiteSpace($UserModulePath)) {
        $NewUserModulePath = $CustomModulePath
    }
    else {
        $NewUserModulePath = "$CustomModulePath;$UserModulePath"
    }

    [System.Environment]::SetEnvironmentVariable(
        'PSModulePath',
        $NewUserModulePath,
        [System.EnvironmentVariableTarget]::User
    )

    Write-Host 'Permanently added the custom module path.' `
        -ForegroundColor Green
}
else {
    Write-Host 'Custom path is already configured permanently.' `
        -ForegroundColor Green
}

#-----------------------------------------------------------
# Remove existing Graph module folders from custom location
#-----------------------------------------------------------

Write-Host ''
Write-Host 'Removing existing Graph modules from the custom location...' `
    -ForegroundColor Cyan

foreach ($ModuleName in $GraphModules) {
    $ExistingModulePath = Join-Path $CustomModulePath $ModuleName

    if (Test-Path -LiteralPath $ExistingModulePath) {
        Remove-Item `
            -LiteralPath $ExistingModulePath `
            -Recurse `
            -Force

        Write-Host "Removed: $ExistingModulePath" `
            -ForegroundColor Yellow
    }
}

#-----------------------------------------------------------
# Download matching module versions
#-----------------------------------------------------------

foreach ($ModuleName in $GraphModules) {
    Write-Host ''
    Write-Host "Downloading $ModuleName $GraphVersion..." `
        -ForegroundColor Cyan

    Save-Module `
        -Name $ModuleName `
        -RequiredVersion $GraphVersion `
        -Path $CustomModulePath `
        -Repository 'PSGallery' `
        -Force `
        -ErrorAction Stop

    $ManifestPath = Join-Path `
        $CustomModulePath `
        "$ModuleName\$GraphVersion\$ModuleName.psd1"

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Module manifest not found after download: $ManifestPath"
    }

    Write-Host "$ModuleName downloaded successfully." `
        -ForegroundColor Green
}

#-----------------------------------------------------------
# Verify downloaded modules
#-----------------------------------------------------------

Write-Host ''
Write-Host 'Downloaded Graph modules:' -ForegroundColor Cyan

Get-Module Microsoft.Graph* -ListAvailable |
    Where-Object {
        $_.ModuleBase -like "$CustomModulePath*"
    } |
    Select-Object Name, Version, ModuleBase |
    Sort-Object Name |
    Format-Table -AutoSize

Write-Host ''
Write-Host 'Installation completed.' -ForegroundColor Green
Write-Host ''
Write-Host 'IMPORTANT:' -ForegroundColor Yellow
Write-Host 'Close this PowerShell window completely.'
Write-Host 'Open a new Windows PowerShell 5.1 window.'
Write-Host 'Then run the import commands shown below.'