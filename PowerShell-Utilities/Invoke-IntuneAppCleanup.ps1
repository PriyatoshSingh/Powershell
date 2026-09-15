#requires -Version 5.1
<#+
.SYNOPSIS
    Assesses and deletes approved Microsoft Intune application objects with guardrails.

.DESCRIPTION
    Default mode is Assess. Delete mode requires an assessment manifest, unchanged input
    CSV, tenant validation, typed confirmation, successful backup, and fresh validation.

    Required Microsoft Graph PowerShell module:
        Microsoft.Graph.Authentication

    Required delegated scope:
        DeviceManagementApps.ReadWrite.All

.INPUT CSV
    Required columns:
        AppId

    Example:
        11111111-1111-1111-1111-111111111111

.NOTES
    Deleting an Intune app object does not uninstall software from endpoints.
    Keep the original source/package separately for rollback or recreation.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputFile,

    [ValidateSet('Assess','Delete')]
    [string]$Mode = 'Assess',

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ExpectedTenantId,

    [string]$ChangeNumber = 'NoChangeNumber',

    [string]$ProtectedAppsFile,

    [string]$AssessmentManifest,

    [ValidateRange(1,50)]
    [int]$MaximumApplications = 10,

    [ValidateRange(1,10)]
    [int]$MaximumDeleteFailures = 2,

    [string]$LogRoot = 'C:\TEMP\AppCleanup',

    [switch]$SkipInteractiveConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RunId = [guid]::NewGuid().Guid
$script:DeleteFailures = 0
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:ConnectedByScript = $false

function Write-RunLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $script:RunId, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

function Add-Result {
    param(
        [string]$AppId,
        [string]$DisplayName,
        [string]$Version,
        [string]$Status,
        [string]$Reason,
        [string]$HttpStatus = '',
        [string]$BackupPath = ''
    )
    $script:Results.Add([pscustomobject]@{
        RunId       = $script:RunId
        Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        TenantId    = $ExpectedTenantId
        ChangeNumber= $ChangeNumber
        Mode         = $Mode
        AppId        = $AppId
        DisplayName  = $DisplayName
        Version      = $Version
        Status       = $Status
        Reason       = $Reason
        HttpStatus   = $HttpStatus
        BackupPath   = $BackupPath
    })
}

function Invoke-GraphSafe {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxRetries = 4
    )
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType PSObject -ErrorAction Stop
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') {
                $status = [int]$_.Exception.ResponseStatusCode
            }
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxRetries) {
                $delay = [math]::Pow(2, $attempt + 1)
                Write-RunLog "Graph returned HTTP $status for $Uri. Retrying in $delay seconds." 'WARN'
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $response = Invoke-GraphSafe -Method GET -Uri $next
        if ($response.PSObject.Properties.Name -contains 'value') {
            foreach ($item in @($response.value)) { $items.Add($item) }
            $next = $response.'@odata.nextLink'
        }
        else {
            $items.Add($response)
            $next = $null
        }
    }
    return @($items)
}

function Get-HttpStatusFromError {
    param([Parameter(Mandatory)]$ErrorRecord)
    if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') {
        return [int]$ErrorRecord.Exception.ResponseStatusCode
    }
    return $null
}

function Save-Json {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Path)
    $Object | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "Backup file was not created: $Path"
    }
}

function Get-AppSnapshot {
    param([Parameter(Mandatory)][string]$AppId,[Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $app = Invoke-GraphSafe -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId"
    $assignments = Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments"

    # Relationships are currently queried through beta because relationship coverage may differ by app type.
    try {
        $outgoing = Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/relationships"
        $allRelationships = Get-GraphCollection -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileAppRelationships'
        $incoming = @($allRelationships | Where-Object { $_.targetId -eq $AppId -and $_.sourceId -ne $AppId })
    }
    catch {
        throw "Relationship validation failed; deletion is blocked. $($_.Exception.Message)"
    }

    Save-Json -Object $app -Path (Join-Path $Destination 'Application.json')
    Save-Json -Object $assignments -Path (Join-Path $Destination 'Assignments.json')
    Save-Json -Object $outgoing -Path (Join-Path $Destination 'OutgoingRelationships.json')
    Save-Json -Object $incoming -Path (Join-Path $Destination 'IncomingRelationships.json')

    return [pscustomobject]@{
        App = $app
        Assignments = @($assignments)
        OutgoingRelationships = @($outgoing)
        IncomingRelationships = @($incoming)
    }
}

function Test-ProtectedApp {
    param([string]$AppId,[object[]]$ProtectedApps)
    return [bool](@($ProtectedApps | Where-Object { [string]$_.AppId -eq $AppId }).Count)
}

# ----- Initial validation and folders -----
$InputFile = (Resolve-Path -LiteralPath $InputFile).Path
if ($ProtectedAppsFile) {
    if (-not (Test-Path -LiteralPath $ProtectedAppsFile -PathType Leaf)) { throw "Protected app file not found: $ProtectedAppsFile" }
    $ProtectedAppsFile = (Resolve-Path -LiteralPath $ProtectedAppsFile).Path
}

$ChangeRoot = Join-Path $LogRoot $ChangeNumber
$RunRoot = Join-Path $ChangeRoot $script:RunId
$BackupRoot = Join-Path $RunRoot 'Backup'
$ReportRoot = Join-Path $RunRoot 'Reports'
$LogFolder = Join-Path $RunRoot 'Logs'
foreach ($folder in @($RunRoot,$BackupRoot,$ReportRoot,$LogFolder)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}
$script:LogFile = Join-Path $LogFolder 'IntuneAppCleanup.log'
$AssessmentReportPath = Join-Path $ReportRoot 'AssessmentReport.csv'
$DeletionReportPath = Join-Path $ReportRoot 'DeletionReport.csv'
$ManifestPath = Join-Path $ReportRoot 'AssessmentManifest.json'

try {
    Write-RunLog "Starting $Mode run. Input=$InputFile; Change=$ChangeNumber"

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $apps = @(Import-Csv -LiteralPath $InputFile)
    if ($apps.Count -eq 0) { throw 'The input CSV contains no records.' }
    if ($apps.Count -gt $MaximumApplications) { throw "Input contains $($apps.Count) apps; maximum allowed is $MaximumApplications." }

    $requiredColumns = @('AppId')
    $actualColumns = @($apps[0].PSObject.Properties.Name)
    foreach ($column in $requiredColumns) {
        if ($column -notin $actualColumns) { throw "Required CSV column is missing: $column" }
    }

    $duplicateIds = @($apps | Group-Object AppId | Where-Object Count -gt 1)
    if ($duplicateIds.Count -gt 0) { throw "Duplicate AppId values found: $($duplicateIds.Name -join ', ')" }

    $InputHash = (Get-FileHash -LiteralPath $InputFile -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $InputFile -Destination (Join-Path $RunRoot 'ApprovedApplications.csv') -Force
    $ProtectedApps = if ($ProtectedAppsFile) { @(Import-Csv -LiteralPath $ProtectedAppsFile) } else { @() }

    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $ExpectedTenantId) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -TenantId $ExpectedTenantId -Scopes 'DeviceManagementApps.ReadWrite.All' -NoWelcome
        $script:ConnectedByScript = $true
        $context = Get-MgContext
    }
    if (-not $context -or $context.TenantId -ne $ExpectedTenantId) {
        throw "Tenant validation failed. Expected $ExpectedTenantId; connected $($context.TenantId)."
    }
    if ('DeviceManagementApps.ReadWrite.All' -notin @($context.Scopes)) {
        throw 'Required delegated scope DeviceManagementApps.ReadWrite.All is not present.'
    }
    Write-RunLog "Tenant validated: $($context.TenantId); Account=$($context.Account)" 'SUCCESS'

    $approvedManifest = $null
    if ($Mode -eq 'Delete') {
        if (-not $AssessmentManifest) { throw 'Delete mode requires -AssessmentManifest from a prior Assess run.' }
        if (-not (Test-Path -LiteralPath $AssessmentManifest -PathType Leaf)) { throw "Assessment manifest not found: $AssessmentManifest" }
        $approvedManifest = Get-Content -LiteralPath $AssessmentManifest -Raw | ConvertFrom-Json
        if ($approvedManifest.InputHash -ne $InputHash) { throw 'Input CSV hash differs from the assessed file. Deletion stopped.' }
        if ($approvedManifest.TenantId -ne $ExpectedTenantId) { throw 'Assessment manifest tenant does not match the expected tenant.' }
        if ($approvedManifest.ChangeNumber -ne $ChangeNumber) { throw 'Assessment manifest change number does not match.' }
    }

    foreach ($row in $apps) {
        $appId = ([string]$row.AppId).Trim()
        $reportName = ''
        $reasons = [System.Collections.Generic.List[string]]::new()

        if ($appId -notmatch '^[0-9a-fA-F-]{36}$') { $reasons.Add('Invalid AppId') }
        if (Test-ProtectedApp -AppId $appId -ProtectedApps $ProtectedApps) { $reasons.Add('AppId is in the protected-app denylist') }

        $appBackup = Join-Path $BackupRoot $appId
        $snapshot = $null
        if ($reasons.Count -eq 0) {
            try {
                $snapshot = Get-AppSnapshot -AppId $appId -Destination $appBackup
                $actualName = [string]$snapshot.App.displayName
                $reportName = $actualName
                if ($snapshot.Assignments.Count -gt 0) { $reasons.Add("Active assignments found: $($snapshot.Assignments.Count)") }
                if ($snapshot.OutgoingRelationships.Count -gt 0) { $reasons.Add("Outgoing relationships found: $($snapshot.OutgoingRelationships.Count)") }
                if ($snapshot.IncomingRelationships.Count -gt 0) { $reasons.Add("Incoming relationships found: $($snapshot.IncomingRelationships.Count)") }
            }
            catch {
                $status = Get-HttpStatusFromError $_
                if ($status -eq 404) { $reasons.Add('Application not found') }
                else { $reasons.Add("Assessment/backup failed: $($_.Exception.Message)") }
            }
        }

        if ($reasons.Count -gt 0) {
            $reasonText = $reasons -join '; '
            Add-Result -AppId $appId -DisplayName $reportName -Status 'Blocked' -Reason $reasonText -BackupPath $appBackup
            Write-RunLog "$appId blocked: $reasonText" 'WARN'
            continue
        }

        if ($Mode -eq 'Assess') {
            Add-Result -AppId $appId -DisplayName $reportName -Status 'Eligible' -Reason 'All assessment guardrails passed' -BackupPath $appBackup
            Write-RunLog "$appId eligible for deletion after approval." 'SUCCESS'
            continue
        }

        $manifestRecord = @($approvedManifest.EligibleApps | Where-Object { $_.AppId -eq $appId })
        if ($manifestRecord.Count -ne 1) {
            Add-Result -AppId $appId -DisplayName $reportName -Status 'Blocked' -Reason 'App was not eligible in the supplied assessment manifest' -BackupPath $appBackup
            Write-RunLog "$appId was not eligible in the assessment manifest." 'WARN'
            continue
        }
        if ([string]$snapshot.App.lastModifiedDateTime -ne [string]$manifestRecord[0].LastModifiedDateTime) {
            Add-Result -AppId $appId -DisplayName $reportName -Status 'Blocked' -Reason 'Application changed after assessment' -BackupPath $appBackup
            Write-RunLog "$appId changed after assessment." 'WARN'
            continue
        }

        # Eligible apps are staged first; actual deletion occurs after the batch summary and typed confirmation.
        Add-Result -AppId $appId -DisplayName $reportName -Status 'ReadyForDeletion' -Reason 'Fresh validation passed' -BackupPath $appBackup
    }

    if ($Mode -eq 'Assess') {
        $script:Results | Export-Csv -LiteralPath $AssessmentReportPath -NoTypeInformation -Encoding UTF8
        $eligible = @($script:Results | Where-Object Status -eq 'Eligible')
        $manifest = [ordered]@{
            SchemaVersion = 1
            RunId = $script:RunId
            CreatedAt = (Get-Date).ToString('o')
            TenantId = $ExpectedTenantId
            ChangeNumber = $ChangeNumber
            InputFile = $InputFile
            InputHash = $InputHash
            EligibleApps = @($eligible | ForEach-Object {
                $appJson = Get-Content -LiteralPath (Join-Path $_.BackupPath 'Application.json') -Raw | ConvertFrom-Json
                [ordered]@{
                    AppId = $_.AppId
                    DisplayName = $_.DisplayName
                    Version = $_.Version
                    LastModifiedDateTime = [string]$appJson.lastModifiedDateTime
                }
            })
        }
        Save-Json -Object $manifest -Path $ManifestPath
        Write-RunLog "Assessment completed. Eligible=$($eligible.Count); Blocked=$(@($script:Results | Where-Object Status -eq 'Blocked').Count)" 'SUCCESS'
        Write-Host "`nAssessment report: $AssessmentReportPath" -ForegroundColor Cyan
        Write-Host "Assessment manifest: $ManifestPath" -ForegroundColor Cyan
        return
    }

    $ready = @($script:Results | Where-Object Status -eq 'ReadyForDeletion')
    $blocked = @($script:Results | Where-Object Status -eq 'Blocked')
    Write-Host "`nTenant:        $ExpectedTenantId"
    Write-Host "Change:        $ChangeNumber"
    Write-Host "Requested:     $($apps.Count)"
    Write-Host "Ready:         $($ready.Count)" -ForegroundColor Yellow
    Write-Host "Blocked:       $($blocked.Count)"

    if ($ready.Count -eq 0) { throw 'No applications passed deletion validation.' }
    if (-not $SkipInteractiveConfirmation) {
        $expectedPhrase = "DELETE-$($ready.Count)-APPLICATIONS"
        $entered = Read-Host "Type $expectedPhrase to continue"
        if ($entered -cne $expectedPhrase) { throw 'Confirmation phrase did not match. Nothing was deleted.' }
    }

    foreach ($item in $ready) {
        if ($script:DeleteFailures -ge $MaximumDeleteFailures) {
            $item.Status = 'Skipped'
            $item.Reason = 'Failure threshold reached'
            continue
        }
        try {
            if ($PSCmdlet.ShouldProcess("$($item.DisplayName) [$($item.AppId)]", 'Delete Intune application object')) {
                Invoke-GraphSafe -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$($item.AppId)" | Out-Null
                Start-Sleep -Seconds 2
                $stillExists = $true
                try {
                    Invoke-GraphSafe -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$($item.AppId)" | Out-Null
                }
                catch {
                    if ((Get-HttpStatusFromError $_) -eq 404) { $stillExists = $false } else { throw }
                }
                if ($stillExists) { throw 'DELETE completed but the app is still retrievable.' }
                $item.Status = 'Deleted'
                $item.Reason = 'DELETE succeeded and subsequent GET returned Not Found'
                $item.HttpStatus = '204/404'
                Write-RunLog "$($item.AppId) deleted and verified." 'SUCCESS'
            }
            else {
                $item.Status = 'WhatIf'
                $item.Reason = 'Deletion was not executed because ShouldProcess declined it'
            }
        }
        catch {
            $script:DeleteFailures++
            $item.Status = 'DeletionFailed'
            $item.Reason = $_.Exception.Message
            $item.HttpStatus = [string](Get-HttpStatusFromError $_)
            Write-RunLog "$($item.AppId) deletion failed: $($_.Exception.Message)" 'ERROR'
        }
    }

    $script:Results | Export-Csv -LiteralPath $DeletionReportPath -NoTypeInformation -Encoding UTF8
    Write-RunLog "Deletion run completed. Deleted=$(@($script:Results | Where-Object Status -eq 'Deleted').Count); Failures=$script:DeleteFailures" 'SUCCESS'
    Write-Host "`nDeletion report: $DeletionReportPath" -ForegroundColor Cyan
}
catch {
    if ($script:LogFile) { Write-RunLog $_.Exception.Message 'ERROR' }
    throw
}
finally {
    if ($script:Results.Count -gt 0) {
        $fallback = if ($Mode -eq 'Assess') { $AssessmentReportPath } else { $DeletionReportPath }
        $script:Results | Export-Csv -LiteralPath $fallback -NoTypeInformation -Encoding UTF8
    }
    if ($script:ConnectedByScript) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
}
