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
The vCenter TLS certificate is validated by default. Certificate validation can be bypassed
only by explicitly passing the -SkipCertificateCheck switch, and the bypass never outlives
the current PowerShell session.
.EXAMPLE
.\powercli-export-vms.ps1
.EXAMPLE
.\powercli-export-vms.ps1 -vCenterAddress vcenter.contoso.com
.EXAMPLE
.\powercli-export-vms.ps1 -vCenterAddress vcenter.contoso.com -vCenterCredential (Get-Credential)
.EXAMPLE
.\powercli-export-vms.ps1 -vCenterAddress vcenter.contoso.com -SkipCertificateCheck
.PARAMETER vCenterAddress
The address of the vCenter server (e.g. vcenter.contoso.com, 1.2.3.4). Please do not include https:// or trailing slash.
.PARAMETER vCenterCredential
The credentials to connect to the vCenter server. You can use the Get-Credential cmdlet to create a credential object.
.PARAMETER SkipCertificateCheck
Disables vCenter TLS certificate validation for this run only. This is insecure and exposes the
connection to man-in-the-middle attacks, so use it only against isolated lab endpoints that present
a self-signed certificate. The preferred fix is to trust the vCenter certificate authority on the
machine running the script. The bypass is scoped to the current session and is reverted before the
script exits, so no machine-wide PowerCLI trust policy change persists.
#>
param(
  [string]$vCenterAddress,
  [PSCredential]$vCenterCredential,
  [switch]$SkipCertificateCheck
)

if (-not $vCenterAddress) {
  $vCenterAddress = Read-Host -Prompt "Enter the vCenter Address (e.g. vcenter.contoso.com, 1.2.3.4:443). Please do not include https:// or trailing slash"
}
if (-not $vCenterCredential) {
  $vCenterCredential = Get-Credential -Message "Enter the vCenter credentials"
}

if ($SkipCertificateCheck) {
  Write-Warning "vCenter TLS certificate validation is disabled for this run. Credentials will be sent over a connection whose server identity has not been verified. Only use -SkipCertificateCheck against trusted lab endpoints."
}

$OutFileCSV = Join-Path -Path $PSScriptRoot -ChildPath "vms.csv"
$OutFileJSON = Join-Path -Path $PSScriptRoot -ChildPath "vms.json"

function exportUsingPowerCLI {
  # Capture the current session trust policy so it can be restored on exit. Certificate
  # validation is enforced by default; it is relaxed only when the caller explicitly opts in,
  # and always in `Session` scope so the machine-wide PowerCLI trust policy is never weakened.
  $previousCertificateAction = $null
  try {
    $previousCertificateAction = (Get-PowerCLIConfiguration -Scope Session -ErrorAction Stop).InvalidCertificateAction
  }
  catch {
    Write-Verbose "Unable to read the current PowerCLI certificate policy: $($_.Exception.Message)"
  }

  $certificateAction = if ($SkipCertificateCheck) { 'Ignore' } else { 'Fail' }
  $viServer = $null

  try {
    # The CEIP preference is not supported in `Session` scope, and it is not a trust setting,
    # so it is applied separately on a best-effort basis to suppress the interactive prompt.
    try {
      Set-PowerCLIConfiguration -ParticipateInCEIP:$false -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
      Write-Verbose "Unable to set the PowerCLI CEIP preference: $($_.Exception.Message)"
    }

    Set-PowerCLIConfiguration -InvalidCertificateAction $certificateAction -Scope Session -Confirm:$false | Out-Null

    $flags = @{}
    if ($vCenterAddress) {
      $flags['Server'] = $vCenterAddress
    }
    if ($vCenterCredential) {
      # Pass the PSCredential straight through so the password is never expanded into a
      # plaintext variable or written to the command line.
      $flags['Credential'] = $vCenterCredential
    }

    try {
      $viServer = Connect-VIServer @flags -ErrorAction Stop
    }
    catch {
      Write-Host "Failed to connect to the vCenter server: $($_.Exception.Message)"
      Write-Host "If this failed because the vCenter presents an untrusted or self-signed certificate, trust its certificate authority on this machine, or re-run with -SkipCertificateCheck to bypass validation for this run only."
      return
    }

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
  }
  finally {
    if ($viServer) {
      Disconnect-VIServer -Server $viServer -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($previousCertificateAction) {
      Set-PowerCLIConfiguration -InvalidCertificateAction $previousCertificateAction -Scope Session -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
  }
}

function exportUsingGovc {

  # govc reads credentials from the environment, so the password is materialised here, kept in
  # process-local environment variables, and cleared in the finally block below.
  $env:GOVC_URL = $vCenterAddress
  $env:GOVC_USERNAME = $vCenterCredential.UserName
  $env:GOVC_PASSWORD = $vCenterCredential.GetNetworkCredential().Password
  # Validate the vCenter certificate unless the caller explicitly opted out.
  $env:GOVC_INSECURE = if ($SkipCertificateCheck) { 'true' } else { 'false' }

  try {
    $vmList = govc find -l -type m
    if (-not $vmList) {
      Write-Host "Failed to connect to the vCenter server. Please check the address and credentials and try again."
      Write-Host "If this failed because the vCenter presents an untrusted or self-signed certificate, trust its certificate authority on this machine, or re-run with -SkipCertificateCheck to bypass validation for this run only."
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
  finally {
    $env:GOVC_PASSWORD = $null
    $env:GOVC_USERNAME = $null
    $env:GOVC_URL = $null
    $env:GOVC_INSECURE = $null
  }
}

$usePowerCLI = $false

if (Get-Command Connect-VIServer -ErrorAction SilentlyContinue) {
  Write-Host "PowerCLI is installed. Exporting VMs using PowerCLI..."
  $usePowerCLI = $true
}
elseif (Get-Command govc -ErrorAction SilentlyContinue) {
  Write-Host "govc is installed. Exporting VMs using govc..."
  $usePowerCLI = $false
}
else {
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
}
else {
  exportUsingGovc
}

Write-Host @"
Inventory data has been exported to:
- CSV file: $OutFileCSV
- JSON file: $OutFileJSON
"@