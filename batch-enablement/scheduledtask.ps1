<#
.SYNOPSIS
This script can be used in Windows environments to run the batch enablement script as a scheduled task. By default, it will register a scheduled task to run the batch enablement script daily at 9am.

.PARAMETER Unregister
If this switch is specified, the script will unregister the scheduled task.

.PARAMETER Export
If this switch is specified, the script will export the scheduled task to a file.

.PARAMETER Logs
If this switch is specified, the script will display the last 10 events from the Task Scheduler logs.

.PARAMETER Start
If this switch is specified, the script will start the scheduled task.

.PARAMETER Stop
If this switch is specified, the script will stop the scheduled task.
#>
param(
  [switch]$Unregister,
  [switch]$Export,
  [switch]$Logs,
  [switch]$Start,
  [switch]$Stop
)

# TODO: Update the task name as needed
$TaskName = "EnableVMs"
# TODO: Update the schedule as needed
# Run daily at 10am
$trigger = New-ScheduledTaskTrigger -Daily -At 10am
# Run every 2 minutes for 1 day
# $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 1) -Once -At "00:00"

if ($Unregister) {
  $TaskName = "EnableVMs"
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "Scheduled task $TaskName unregistered successfully."
  return
}

if ($Export) {
  $ExportFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableVMs-ScheduledTask.xml"
  Export-ScheduledTask -TaskName $TaskName | Out-File -FilePath $ExportFile
  Write-Host "Scheduled task $TaskName exported to $ExportFile."
  return
}

if ($Logs) {
  Get-WinEvent  -FilterXml @"
     <QueryList>
      <Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational">
       <Select Path="Microsoft-Windows-TaskScheduler/Operational">
        *[EventData/Data[@Name='TaskName']='\$TaskName']
       </Select>
      </Query>
     </QueryList>
"@  -ErrorAction Stop -MaxEvents 10
  return
}

$currentTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($Start) {
  if ($currentTask) {
    Write-Host "Starting scheduled task $TaskName."
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Scheduled task $TaskName started successfully."
  } else {
    Write-Host "Scheduled task $TaskName not found. Please register the task first."
  }
  return
}

if ($Stop) {
  Stop-ScheduledTask -TaskName $TaskName
  return
}

if ($currentTask) {
  Write-Host "Scheduled task $TaskName already exists.Unregistering the existing task."
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "batch-runner.ps1"
if (-not (Test-Path -Path $scriptPath)) {
  Write-Host "batch-runner.ps1 not found in $PSScriptRoot. Please ensure the script is present and try again."
  return
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NoLogo -NonInteractive' + " -File $scriptPath") -WorkingDirectory ("$PSScriptRoot")
$Settings = New-ScheduledTaskSettingsSet -DontStopOnIdleEnd -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -RestartOnIdle -WakeToRun -RunOnlyIfNetworkAvailable
$Settings.ExecutionTimeLimit = "PT0S"
$VMCredential = Get-Credential -Message "Enter the user credentials used for running the scheduled task"
$user = $VMCredential.UserName
$pass = $VMCredential.GetNetworkCredential().Password
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $TaskName -User $user -Password $pass -Settings $Settings
Write-Host "Scheduled task $TaskName registered successfully."
