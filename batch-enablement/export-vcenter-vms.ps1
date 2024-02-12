<#
.SYNOPSIS
This is a helper script for exporting the vCenter VM inventory data using PowerCLI or govc.
It prefers PowerCLI over govc if both are installed.
For each VM, it exports the following properties:
- Connection State
- Guest ID
- Guest Family
- Guest Full Name
- Host Name
- MoRef ID
- Power State
- Tools Version
- Tools Version Status
- Tools Running Status
- VM Name

The script asks for the credentials interactively if they are not provided as parameters.
The data is exported in CSV and JSON formats in the current working directory.

.EXAMPLE
.\export-vcenter-vms.ps1

.EXAMPLE
.\export-vcenter-vms.ps1 -vCenterAddress vcenter.contoso.com

.EXAMPLE
.\export-vcenter-vms.ps1 -vCenterAddress vcenter.contoso.com -vCenterCredential (Get-Credential)

.PARAMETER vCenterAddress
The address of the vCenter server (e.g. vcenter.contoso.com, 1.2.3.4). Please do not include https:// or trailing slash.

.PARAMETER vCenterCredential
The credentials to connect to the vCenter server. You can use the Get-Credential cmdlet to create a credential object.
#>
param(
  [string]$vCenterAddress,
  [PSCredential]$vCenterCredential
)

if (-not $vCenterAddress) {
  $vCenterAddress = Read-Host -Prompt "Enter the vCenter Address (e.g. vcenter.contoso.com, 1.2.3.4:443). Please do not include https:// or trailing slash"
}
if (-not $vCenterCredential) {
  $vCenterCredential = Get-Credential -Message "Enter the vCenter credentials"
}
$vCenterUser = $vCenterCredential.UserName
$vCenterPass = $vCenterCredential.GetNetworkCredential().Password

function exportUsingPowerCLI {
  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP:$false -Confirm:$false | Out-Null
  
  $flags = @{}
  if ($vCenterAddress) {
    $flags['Server'] = $vCenterAddress
  }
  if ($vCenterCredential) {
    $flags['User'] = $vCenterUser
    $flags['Password'] = $vCenterPass
  }
  $viServer = Connect-VIServer @flags

  # Get-VM docs :
  # https://developer.vmware.com/docs/powercli/latest/vmware.vimautomation.core/commands/get-vm/#Default
  # Properties Returned by Get-VM:
  # https://developer.vmware.com/docs/powercli/latest/vmware.vimautomation.core/structures/vmware.vimautomation.vicore.types.v1.inventory.virtualmachine/
  $vmList = Get-VM -Server $viServer
  $vms = @()
  foreach ($vm in $vmList) {
    if ($vm.ExtensionData.Config.Template) {
      continue
    }
    $vmInfo = [ordered]@{
      vmName             = "$($vm.ExtensionData.Name)"
      moRefId            = "$($vm.ExtensionData.MoRef.Value)"
      connectionState    = "$($vm.ExtensionData.Summary.Runtime.ConnectionState)"
      guestId            = "$($vm.ExtensionData.Guest.GuestId)"
      guestFamily        = "$($vm.ExtensionData.Guest.GuestFamily)"
      guestFullName      = "$($vm.ExtensionData.Guest.GuestFullName)"
      hostName           = "$($vm.ExtensionData.Guest.HostName)"
      powerState         = "$($vm.ExtensionData.Summary.Runtime.PowerState)"
      toolsVersion       = "$($vm.ExtensionData.Guest.ToolsVersion)"
      toolsVersionStatus = "$($vm.ExtensionData.Guest.ToolsVersionStatus2)"
      toolsRunningStatus = "$($vm.ExtensionData.Guest.ToolsRunningStatus)"
    }
    $vms += $vmInfo
  }
  $vms | ConvertTo-Csv | Out-File -FilePath vms.csv
  $vms | ConvertTo-Json | Out-File -FilePath vms.json
  Disconnect-VIServer -Server $viServer -Confirm:$false
}

function exportUsingGovc {

  $env:GOVC_URL = $vCenterAddress
  $env:GOVC_USERNAME = $vCenterUser
  $env:GOVC_PASSWORD = $vCenterPass
  $env:GOVC_INSECURE = 'true'

  $vmList = govc find -l -type m
  $vms = @()
  foreach ($vmEntry in $vmList) {
    $vmPath = $vmEntry -replace '^VirtualMachine\s+', ''
    $vmInfo = govc object.collect -json $vmPath summary guest | ConvertFrom-Json
    $summary = $vmInfo | Where-Object { $_.Name -eq 'summary' } | Select-Object -ExpandProperty val
    $guest = $vmInfo | Where-Object { $_.Name -eq 'guest' } | Select-Object -ExpandProperty val
    if ($summary.config.template) {
      continue
    }
    $vm = [ordered]@{
      vmName             = "$($summary.config.name)"
      moRefId            = "$($summary.vm.value)"
      connectionState    = "$($summary.runtime.connectionState)"
      guestId            = "$($guest.guestId)"
      guestFamily        = "$($guest.guestFamily)"
      guestFullName      = "$($guest.guestFullName)"
      hostName           = "$($guest.hostName)"
      powerState         = "$($summary.runtime.powerState)"
      toolsVersion       = "$($guest.toolsVersion)"
      toolsVersionStatus = "$($guest.toolsVersionStatus2)"
      toolsRunningStatus = "$($guest.toolsRunningStatus)"
    }
    $vms += $vm
  }
  $vms | ConvertTo-Csv | Out-File -FilePath vms.csv
  $vms | ConvertTo-Json | Out-File -FilePath vms.json
}

$usePowerCLI = $false

if (Get-Command Connect-VIServer -ErrorAction SilentlyContinue) {
  $usePowerCLI = $true
} elseif (Get-Command govc -ErrorAction SilentlyContinue) {
  $usePowerCLI = $false
} else {
  Write-Host @"
PowerCLI or govc is not installed. Please install either PowerCLI or govc and try again.

PowerCLI can be installed using the following command:
Install-Module -Name VMware.PowerCLI -Scope AllUsers -Confirm:$false -Force

You can install govc by downloading the latest release from https://github.com/vmware/govmomi/releases
$url = "https://github.com/vmware/govmomi/releases/download/v0.34.2/govc_Windows_x86_64.zip"
Invoke-WebRequest -Uri $url -OutFile govc.zip
Expand-Archive -Path govc.zip -DestinationPath $env:ProgramFiles # Windows
Expand-Archive -Path govc.zip -DestinationPath /usr/local/bin # Linux
"@
  return
}

if ($usePowerCLI) {
  exportUsingPowerCLI
} else {
  exportUsingGovc
}
