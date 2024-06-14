# TODO: Update the path to the folder containing the credentials
$credsFolder = $PSScriptRoot

$batchEnableScriptPath = Join-Path $PSScriptRoot -ChildPath "arcvmware-batch-enablement.ps1"

$RunGroups = @(
  @{
    VCenterId    = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter-1"
    CredsFileName = "creds-contoso-vcenter-1.xml"
  },
  @{
    VCenterId    = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter-2"
    CredsFileName = "creds-contoso-vcenter-2.xml"
  },
  @{
    VCenterId    = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter-3"
    CredsFileName = "creds-contoso-vcenter-3.xml"
    ARGFilter    = "| where osName contains 'Windows' and toolsVersion > 11365 and ipAddresses hasprefix '172.'"
  },
  @{
    VCenterId    = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter-4"
    CredsFileName = "creds-contoso-vcenter-4.xml"
    ARGFilter    = "| where osName !in~ ('Windows', 'BSD', 'Photon') and toolsVersion > 10346 | extend ipAddr=ipAddresses | mv-expand ipAddr | where ipv4_is_in_range(tostring(ipAddr), '172.16.18.0/21') | summarize take_any(ipAddr, *) by Name | project-away ipAddr"
  }
)

function RunBatchEnablement {
  param (
    [string]$VCenterId,
    [System.Object]$Rungroup
  )

  $CredsFilePath = Join-Path $credsFolder -ChildPath $Rungroup.CredsFileName
  Write-Host "Running batch enablement for $VCenterId"
  $params = @{
    VCenterId             = $VCenterId
    EnableGuestManagement = $true
    UseDiscoveredInventory = $true
    VMCredsFile           = $CredsFilePath
    # Execute               = $true # TODO: Uncomment to execute
  }
  if ($ARGFilter) {
    $params.Add("ARGFilter", $ARGFilter)
  }
  & $batchEnableScriptPath @params
}

Write-Host "Running batch enablement sequentially between rungroups."
$RunGroups | ForEach-Object {
  RunBatchEnablement -VCenterId $_.VCenterId -Rungroup $_
}
