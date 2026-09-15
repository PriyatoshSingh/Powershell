#CompanyName = 'MCO - Moodys Shared Services'
#Line of Business = 'TSG - Technology Services Group'
#Team = 'Digital Workplace Services - Ops'
#Author = 'Setu Ashwin'
#Date = 20-May-2025
#Updated on 13-Jan-2026 to replace Azure AD Cmdlets with Graph API.

#Connect Graph API using the Graph API Service Principal for Ops

#Provides access via "Graph-SDK-User-WSDE-Intune-OPS" Azure/Enterprise App with graph API permissions.
<#
App has the following permissions, but since it uses delegated access, least of your SA account and App permissions will be applied.
Use context only where necessassry.
Use Graph Explorer or Graph Xray for permissions
                Application.ReadWrite.All
                AuditLog.Read.All
                Device.Read.All
                DeviceManagementApps.Read.All
                DeviceManagementApps.ReadWrite.All
                DeviceManagementConfiguration.Read.All
                DeviceManagementConfiguration.ReadWrite.All
                DeviceManagementManagedDevices.PrivilegedOperations.All
                DeviceManagementManagedDevices.Read.All
                DeviceManagementManagedDevices.ReadWrite.All
                DeviceManagementRBAC.Read.All
                DeviceManagementServiceConfig.Read.All
                DeviceManagementServiceConfig.ReadWrite.All
                Directory.ReadWrite.All
                email
                Group.Read.All
                GroupMember.ReadWrite.All
                User.Read.All
                WindowsUpdates.ReadWrite.All
                profile
                openid

#>

$ClientID = "bc5e485d-da01-412a-90aa-982f551f078e"
$Scopes = "User.Read.All"
$TenantID = "1061a8b8-b1ee-4249-bb84-9a2cd2792fae"
connect-mggraph -ClientId $ClientID -Scopes $Scopes -TenantId $TenantID

# Variables
$CHG = Read-Host "Enter the CHG number"
$Wave = Read-Host "Enter the Wave number"
$date = Get-Date -Format ddMMMyyyy
$csv = Read-Host "Enter the CSV full path, ensure there is only column named Devices"
$csv = $csv.Trim('"')
$groupObjectId = Read-Host "Enter the Group Object ID"

if ([string]::IsNullOrWhiteSpace($CHG) -or [string]::IsNullOrWhiteSpace($Wave)) {
    Write-Host "CHG number and Wave number cannot be empty."
    exit
}

$logpath = "C:\temp\$CHG-Wave$Wave-$date.log"
Start-Transcript -Path $logpath -Append

try {
    $devices = Import-Csv -Path $csv
} catch {
    Write-Host "Failed to import CSV file. $_"
    Stop-Transcript
    exit
}

Write-Host "We are attempting to add $($devices.Count) devices"
$count = 0
$results = @() # Array to store results for output

do {
    try {
        #$group = Get-AzureADGroup -ObjectId $groupObjectId -ErrorAction Stop #Needs a change
        $group = Get-MgGroup -GroupId $groupObjectId -ErrorAction Stop
    } catch {
        Write-Host "Failed to retrieve group. $_"
        $group = $null
    }

    if ($null -ne $group) {
        Write-Host "Group $($group.DisplayName) found"
        $accept = Read-Host "Do you want to continue adding devices to this group? (Y/N)"
        if ($accept.ToUpper() -eq "Y") {
            break
        } else {
            $groupObjectId = Read-Host "Enter the Group Object ID"
        }
    } else {
        Write-Host "Group not found"
        $groupObjectId = Read-Host "Enter the Group Object ID"
    }
} while ($null -eq $group)

foreach ($device in $devices) {
    try {
        #$azureDevices = Get-AzureADDevice -SearchString "$($device.Devices)" -Verbose -ErrorAction Stop #Needs a change
        $azureDevices = Get-MgDevice -Filter "Displayname eq '$($device.Devices)'" -Verbose -ErrorAction Stop
        Write-Host "$($azureDevices.Count) device(s) found for Displayname $($device.Devices)"
    } catch {
        Write-Host "Failed to retrieve devices for $($device.Devices). $_"
        $results += [PSCustomObject]@{
            DeviceName = $device.Devices
            ObjectId   = ''
            Status     = 'Failed'
            Message    = "Failed to retrieve device(s): $_"
        }
        continue
    }

    foreach ($azureDevice in $azureDevices) {
        if ($azureDevice.IsManaged -eq $true -and $azureDevice.TrustType -eq "ServerAd") {
            try {
                #Add-AzureADGroupMember -ObjectId $groupObjectId -RefObjectId $($azureDevice.ObjectId) -ErrorAction Stop | Out-Null #Needs a change
                New-MgGroupMember -GroupId $groupObjectId -DirectoryObjectId $($azureDevice.Id) -ErrorAction Stop | Out-Null
                Write-Host "$($azureDevice.DisplayName) with Azure Object ID: $($azureDevice.Id) added"
                $count++
                $results += [PSCustomObject]@{
                    DeviceName = $azureDevice.DisplayName
                    ObjectId   = $azureDevice.Id
                    Status     = 'Added'
                    Message    = 'Device added to group'
                }
            } catch {
                Write-Host "$($azureDevice.DisplayName) with Azure Object ID: $($azureDevice.Id) failed to add. $_"
                $results += [PSCustomObject]@{
                    DeviceName = $azureDevice.DisplayName
                    ObjectId   = $azureDevice.Id
                    Status     = 'Failed'
                    Message    = "Failed to add device: $_"
                }
            }
        } else {
            $results += [PSCustomObject]@{
                DeviceName = $azureDevice.DisplayName
                ObjectId   = $azureDevice.Id
                Status     = 'Skipped'
                Message    = 'Device not managed or not Hybrid Joined'
            }
        }
    }
}

Write-Host "$count devices added"

# Export results to CSV
$outputPath = "C:\temp\$CHG-Wave$Wave-$date-Results.csv"
$results | Export-Csv -Path $outputPath -NoTypeInformation
Write-Host "Results exported to $outputPath"

Stop-Transcript