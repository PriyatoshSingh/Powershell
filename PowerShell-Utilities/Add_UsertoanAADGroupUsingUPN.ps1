#CompanyName = 'MCO - Moodys Shared Services'
#Line of Business = 'TSG - Technology Services Group'
#Team = 'Digital Workplace Services - Ops'
#Author = Setu Ashwin
#Date = 31-Mar-2026

#Connect Graph API using the Graph API Service Principal for Ops

$environment = Read-Host "Enter the environment (Prod/MCOLab)"
switch ($environment.ToLower())
{
    "prod" { $ClientID = "bc5e485d-da01-412a-90aa-982f551f078e"; $TenantID = "1061a8b8-b1ee-4249-bb84-9a2cd2792fae" }
    "mcolab" { $ClientID = "d787b2a9-9d27-4c1a-bb84-b4dc02eb1dc1"; $TenantID = "362d46e6-5194-475d-87c6-04bedfb7e61a" }
    default { Write-Host "Invalid environment. Please enter 'Prod' or 'MCOLab'."; exit }
}

$Scopes = "User.Read.All"
Connect-MgGraph -ClientId $ClientID -Scopes $Scopes -TenantId $TenantID

# Variables
$CHG = Read-Host "Enter the CHG number"
$Wave = Read-Host "Enter the Wave number"
$date = Get-Date -Format ddMMMyyyy
$csv = Read-Host "Enter the CSV full path, ensure there is only column named UPN"
$csv = $csv.Trim('"')
$groupObjectId = Read-Host "Enter the Group Object ID"

if ([string]::IsNullOrWhiteSpace($CHG) -or [string]::IsNullOrWhiteSpace($Wave))
{
    Write-Host "CHG number and Wave number cannot be empty."
    exit
}

$logpath = "C:\temp\$CHG-Wave$Wave-$date.log"
Start-Transcript -Path $logpath -Append

try
{
    $users = Import-Csv -Path $csv
}
catch
{
    Write-Host "Failed to import CSV file. $_"
    Stop-Transcript
    exit
}

Write-Host "We are attempting to add $($users.Count) users"

$count = 0
$results = @()

do
{
    try
    {
        $group = Get-MgGroup -GroupId $groupObjectId -ErrorAction Stop
    }
    catch
    {
        Write-Host "Failed to retrieve group. $_"
        $group = $null
    }

    if ($null -ne $group)
    {
        Write-Host "Group $($group.DisplayName) found"

        $accept = Read-Host "Do you want to continue adding users to this group? (Y/N)"

        if ($accept.ToUpper() -eq "Y")
        {
            break
        }
        else
        {
            $groupObjectId = Read-Host "Enter the Group Object ID"
        }
    }
    else
    {
        Write-Host "Group not found"
        $groupObjectId = Read-Host "Enter the Group Object ID"
    }
}
while ($null -eq $group)

foreach ($user in $users)
{
    try
    {
        $graphUser = Get-MgUser -UserId $user.UPN -ErrorAction Stop
        Write-Host "User found for UPN $($user.UPN)"
    }
    catch
    {
        Write-Host "Failed to retrieve user for $($user.UPN). $_"

        $results += [PSCustomObject]@{
            UPN      = $user.UPN
            ObjectId = ''
            Status   = 'Failed'
            Message  = "Failed to retrieve user: $_"
        }

        continue
    }

    if ($null -ne $graphUser)
    {
        try
        {
            New-MgGroupMember -GroupId $groupObjectId -DirectoryObjectId $graphUser.Id -ErrorAction Stop | Out-Null

            Write-Host "$($graphUser.DisplayName) with UPN $($user.UPN) added to the group"

            $count++

            $results += [PSCustomObject]@{
                UPN      = $user.UPN
                ObjectId = $graphUser.Id
                Status   = 'Added'
                Message  = 'User added to group'
            }
        }
        catch
        {
            Write-Host "$($graphUser.DisplayName) with UPN $($user.UPN) failed to add. $_"

            $results += [PSCustomObject]@{
                UPN      = $user.UPN
                ObjectId = $graphUser.Id
                Status   = 'Failed'
                Message  = "Failed to add user: $_"
            }
        }
    }
    else
    {
        $results += [PSCustomObject]@{
            UPN      = $user.UPN
            ObjectId = ''
            Status   = 'Not Found'
            Message  = 'User not found in Azure AD'
        }
    }
}

Write-Host "$count users added"

# Export results to CSV
$outputPath = "C:\temp\$CHG-Wave$Wave-$date-Results.csv"
$results | Export-Csv -Path $outputPath -NoTypeInformation

Write-Host "Results exported to $outputPath"

Stop-Transcript