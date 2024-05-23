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
The data is exported in CSV and JSON formats in the same directory as the script.

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

$OutFileCSV = Join-Path -Path $PSScriptRoot -ChildPath "vms.csv"
$OutFileJSON = Join-Path -Path $PSScriptRoot -ChildPath "vms.json"

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

  if (-not $viServer) {
    Write-Host "Failed to connect to the vCenter server. Please check the address and credentials and try again."
    return
  }
  Write-Host "Connected to the vCenter server: $viServer . Fetching VMs..."

  # Get-VM docs :
  # https://developer.vmware.com/docs/powercli/latest/vmware.vimautomation.core/commands/get-vm/#Default
  # Properties Returned by Get-VM:
  # https://developer.vmware.com/docs/powercli/latest/vmware.vimautomation.core/structures/vmware.vimautomation.vicore.types.v1.inventory.virtualmachine/
  $vmList = VMware.VimAutomation.Core\Get-VM -Server $viServer
  $vms = @()
  foreach ($vm in $vmList) {
    if ($vm.ExtensionData.Config.Template) {
      continue
    }
    $guestId = $vm.ExtensionData.Summary.Guest.GuestId
    if (-not $guestId) {
      $guestId = $vm.ExtensionData.Summary.Config.GuestId
    }
    $guestFullName = $vm.ExtensionData.Summary.Guest.GuestFullName
    if (-not $guestFullName) {
      $guestFullName = $vm.ExtensionData.Summary.Config.GuestFullName
    }
    $vmInfo = [PSCustomObject] @{
      vmName             = "$($vm.ExtensionData.Name)"
      moRefId            = "$($vm.ExtensionData.MoRef.Value)"
      connectionState    = "$($vm.ExtensionData.Summary.Runtime.ConnectionState)"
      guestId            = "$($guestId)"
      guestFamily        = "$($vm.ExtensionData.Guest.GuestFamily)"
      guestFullName      = "$($guestFullName)"
      hostName           = "$($vm.ExtensionData.Summary.Guest.HostName)"
      powerState         = "$($vm.ExtensionData.Summary.Runtime.PowerState)"
      toolsVersion       = "$($vm.ExtensionData.Guest.ToolsVersion)"
      toolsVersionStatus = "$($vm.ExtensionData.Summary.Guest.ToolsVersionStatus2)"
      toolsRunningStatus = "$($vm.ExtensionData.Summary.Guest.ToolsRunningStatus)"
    }
    $vms += $vmInfo
  }
  $vms | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutFileJSON
  $vms | Export-Csv -Path $OutFileCSV -NoTypeInformation
  Disconnect-VIServer -Server $viServer -Confirm:$false
}

function exportUsingGovc {

  $env:GOVC_URL = $vCenterAddress
  $env:GOVC_USERNAME = $vCenterUser
  $env:GOVC_PASSWORD = $vCenterPass
  $env:GOVC_INSECURE = 'true'

  $vmList = govc find -l -type m
  if (-not $vmList) {
    Write-Host "Failed to connect to the vCenter server. Please check the address and credentials and try again."
    return
  }
  Write-Host "Connected to the vCenter server: $vCenterAddress . Fetching VMs..."
  $vms = @()
  foreach ($vmEntry in $vmList) {
    $vmPath = $vmEntry -replace '^VirtualMachine\s+', ''
    $vmInfo = govc object.collect -json $vmPath summary guest | ConvertFrom-Json
    $summary = $vmInfo | Where-Object { $_.Name -eq 'summary' } | Select-Object -ExpandProperty val
    $guest = $vmInfo | Where-Object { $_.Name -eq 'guest' } | Select-Object -ExpandProperty val
    if ($summary.config.template) {
      continue
    }
    $guestId = $summary.config.guestId
    if (-not $guestId) {
      $guestId = $guest.guestId
    }
    $guestFullName = $summary.config.guestFullName
    if (-not $guestFullName) {
      $guestFullName = $guest.guestFullName
    }
    $vm = [PSCustomObject] @{
      vmName             = "$($summary.config.name)"
      moRefId            = "$($summary.vm.value)"
      connectionState    = "$($summary.runtime.connectionState)"
      guestId            = "$($guestId)"
      guestFamily        = "$($guest.guestFamily)"
      guestFullName      = "$($guestFullName)"
      hostName           = "$($summary.guest.hostName)"
      powerState         = "$($summary.runtime.powerState)"
      toolsVersion       = "$($guest.toolsVersion)"
      toolsVersionStatus = "$($summary.guest.toolsVersionStatus2)"
      toolsRunningStatus = "$($summary.guest.toolsRunningStatus)"
    }
    $vms += $vm
  }
  $vms | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutFileJSON
  $vms | Export-Csv -Path $OutFileCSV -NoTypeInformation
}

$usePowerCLI = $false

if (Get-Command Connect-VIServer -ErrorAction SilentlyContinue) {
  Write-Host "PowerCLI is installed. Exporting VMs using PowerCLI..."
  $usePowerCLI = $true
} elseif (Get-Command govc -ErrorAction SilentlyContinue) {
  Write-Host "govc is installed. Exporting VMs using govc..."
  $usePowerCLI = $false
} else {
  Write-Host @"
PowerCLI or govc is not installed. Please install either PowerCLI or govc and try again.

PowerCLI can be installed using the following command:
Install-Module -Name VMware.PowerCLI -Scope AllUsers -Confirm:`$false -Force

You can install govc by downloading the latest release from https://github.com/vmware/govmomi/releases
`$url = "https://github.com/vmware/govmomi/releases/download/v0.34.2/govc_Windows_x86_64.zip"
Invoke-WebRequest -Uri `$url -OutFile govc.zip
Expand-Archive -Path govc.zip -DestinationPath `$env:SystemRoot\System32 # Windows
Expand-Archive -Path govc.zip -DestinationPath /usr/local/bin # Linux
"@
  return
}

if ($usePowerCLI) {
  exportUsingPowerCLI
} else {
  exportUsingGovc
}

Write-Host @"
Inventory data has been exported to:
- CSV file: $OutFileCSV
- JSON file: $OutFileJSON
"@
