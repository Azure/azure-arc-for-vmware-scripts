<#
.SYNOPSIS
This is a helper script to deboard your vCenter and associated resources from Azure Arc enabled VMware or Azure Arc enabled AVS.

.PARAMETER vCenterId
The vCenter ARM Id. If you are using Azure Arc enabled VMware, provide the vCenter ARM Id.

.PARAMETER AVSId
The AVS ARM Id. If you are using Azure Arc enabled AVS, provide the AVS ARM Id.

.PARAMETER ApplianceConfigFilePath
The path to the appliance config file which was generated during onboarding. If your resource bridge is named contoso-rb, then 'contoso-rb-appliance.yaml' will be the file name. If you don't have the appliance config file, just the appliance resource will be deleted from Azure but the appliance VM will not be deleted from the vCenter.

.EXAMPLE
PS C:\> .\arcvmware-deboard.ps1 -vCenterId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/VCenters/contoso-vcenter"

.EXAMPLE
PS C:\> .\arcvmware-deboard.ps1 -AVSId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/contoso-rg/providers/Microsoft.AVS/privateClouds/contoso-avs"

.EXAMPLE
PS C:\> .\arcvmware-deboard.ps1 -ApplianceConfigFilePath "C:\Users\contoso\Downloads\contoso-rb-appliance.yaml" -vCenterId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/VCenters/contoso-vcenter"

#>
[CmdletBinding()]
Param(
  [string] $vCenterId,
  [string] $AVSId,
  [switch] $DeleteAppliance,
  [string] $ApplianceConfigFilePath
)

$DeleteFailedThreshold = 20
$AVS_API_Version = "2022-05-01"
$VM_API_Version = "2023-03-01-preview"

$logFile = Join-Path $PSScriptRoot "arcvmware-deboard.log"

function logText() {
  param(
    [Parameter(Mandatory = $true)]
    [string] $msg,
    [ConsoleColor] $color
  )
  $msgFull = "$(Get-Date -UFormat '%T') $msg"
  if ($null -eq $color) {
    Write-Host $msgFull
  }
  else {
    Write-Host $msgFull -ForegroundColor $color
  }
  Write-Output $msgFull >> $logFile
}

function fail($msg) {
  $msgFull = @"
  $(Get-Date -UFormat '%T') Script execution failed with error: $msg
  $(Get-Date -UFormat '%T') Debug logs have been dumped to $logFile
  $(Get-Date -UFormat '%T') The script will terminate shortly
"@
  Write-Host -ForegroundColor Red $msgFull >> $logFile
  Write-Output $msgFull >> $logFile
  Start-Sleep -Seconds 5
  exit 1
}

function confirmationPrompt($msg) {
  Write-Host $msg
  while ($true) {
    $inp = Read-Host "Yes(y)/No(n)?"
    $inp = $inp.ToLower()
    if ($inp -eq 'y' -or $inp -eq 'yes') {
      return $true
    }
    elseif ($inp -eq 'n' -or $inp -eq 'no') {
      return $false
    }
  }
}

function extractPartsFromID($id) {
  if ($id -match "/+subscriptions/+([^/]+)/+resourceGroups/+([^/]+)/+providers/+([^/]+)/+([^/]+)/+([^/]+)") {
    return @{
      SubscriptionId = $Matches[1]
      ResourceGroup  = $Matches[2]
      Provider       = $Matches[3]
      Type           = $Matches[4]
      Name           = $Matches[5]
    }
  }
  else {
    return $null
  }
}

if ($PSBoundParameters.ContainsKey('vCenterId') -and $PSBoundParameters.ContainsKey('AVSId')) {
  fail "Please specify either vCenterId or AVSId, not both."
}
if (-not($PSBoundParameters.ContainsKey('vCenterId') -or $PSBoundParameters.ContainsKey('AVSId'))) {
  $resId = Read-Host "Please enter the vCenter ARM Id or the AVS ARM Id"

  $invalidResIdMsg = @"
The provided ARM ID is not a valid AVSId or vCenterId: $resId
Sample AVSId: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/contoso-rg/providers/Microsoft.AVS/privateClouds/contoso-avs
Sample vCenterId: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/VCenters/contoso-vcenter
"@

  $resInfo = extractPartsFromID $resId
  if ($null -eq $resInfo) {
    fail $invalidResIdMsg
  }
  if ($resInfo.Provider -eq "Microsoft.AVS" -and $resInfo.Type -eq "privateClouds") {
    $AVSId = $resId
  }
  elseif ($resInfo.Provider -eq "Microsoft.ConnectedVMwarevSphere" -and $resInfo.Type -eq "VCenters") {
    $vCenterId = $resId
  }
  else {
    fail $invalidResIdMsg
  }
}

if ($PSBoundParameters.ContainsKey('ApplianceConfigFilePath')) {
  if (-not (Test-Path $ApplianceConfigFilePath)) {
    fail "The appliance config file path '$ApplianceConfigFilePath' does not exist."
  }
}

logText "Writing debug logs to $logFile"

logText "Installing az cli extensions for Arc"
az extension add --upgrade --name arcappliance
az extension add --upgrade --name k8s-extension
az extension add --upgrade --name customlocation
az extension add --upgrade --name connectedvmware
az extension add --upgrade --name resource-graph

logText "Fetching some information related to the vCenter..."
if ($PSBoundParameters.ContainsKey('AVSId')) {
  $vCenterId = az rest --method get --url "$AVSId/addons/arc?api-version=$AVS_API_Version" --query "properties.vCenter" -o tsv --debug 2>> $logFile
  if ($null -eq $vCenterId) {
    fail "Unable to find vCenter ID for AVS $AVSId"
  }
  logText "vCenterId is $vCenterId"
}
else {
  $exists = az connectedvmware vcenter show --ids $vCenterId --debug 2>> $logFile
  if ($null -eq $exists) {
    fail "Unable to find vCenter ID $vCenterId"
  }
}

$ApplianceId = $null

function cleanupAppliance {
  if ($null -ne $ApplianceId) {
    $otherCustomLocationsInAppliance = $(az graph query -q @"
  Resources
  | where type =~ 'Microsoft.ExtendedLocation/customLocations'
  | where id !~ '$customLocationID'
  | where properties.hostResourceId =~ '$ApplianceId'
  | project id
"@.Replace("`r`n", " ").Replace("`n", " ") --debug 2>> $logFile | ConvertFrom-Json).data.id

    if ($otherCustomLocationsInAppliance.Count -gt 0) {
      logText "Warning: There are other custom locations in the appliance." -color Yellow
      logText "The custom location IDs of these custom locations are:`n  $($otherCustomLocationsInAppliance -join "`n  ")" -color Yellow
      $deleteApplMsg = @'
There are other Custom Locations present linked with the resource bridge. Do you want to proceed with deboarding?
'@
      if (!(confirmationPrompt -msg $deleteApplMsg)) {
        logText "Exiting the script..."
        exit 0
      }
    } 
  }

  if ($ApplianceConfigFilePath) {
    logText "Deleting the appliance using the config file: $ApplianceConfigFilePath"
    az arcappliance delete vmware --debug --yes --config-file $ApplianceConfigFilePath 2>> $logFile
    if ($LASTEXITCODE -ne 0) {
      fail "Failed to delete $ApplianceId"
    }
  }
  elseif ($null -ne $ApplianceId) {
    logText "Skipping the deletion of the appliance VM on the VCenter because the appliance config file path is not provided"
    logText "Just deleting the ARM resource of the appliance: $ApplianceId"
    az resource delete --debug --ids $ApplianceId 2>> $logFile
    if ($LASTEXITCODE -ne 0) {
      fail "Failed to delete $ApplianceId"
    }
  } else {
    logText "Skipping the deletion of the appliance because neither the appliance config file path is provided nor the appliance ARM resource could be figured out from the custom location" -color Yellow
  }
}

$customLocationID = az resource show --ids $vCenterId --query extendedLocation.name -o tsv --debug 2>> $logFile
logText "Extracted custom location: $customLocationID"
$customLocation = az resource show --ids $customLocationID --debug 2>> $logFile | ConvertFrom-Json

if ($null -ne $customLocation) {
  $ApplianceId = $customLocation.properties.hostResourceId
}
cleanupAppliance
if ($null -ne $customLocation) {
  logText "Deleting the custom location: $customLocationID"
  $clInfo = extractPartsFromID $customLocationID
  az customlocation delete --debug --yes --subscription $clInfo.SubscriptionId --resource-group $clInfo.ResourceGroup --name $clInfo.Name 2>> $logFile
  # The command above is returning error when the cluster is not reachable, so $LASTEXITCODE is not reliable.
  # Instead, check if resource is not found after delete, else throw error.
  $cl = az resource show --ids $customLocationID --debug 2>> $logFile
  if ($cl) {
    fail "Failed to delete $customLocationID"
  }
}

$VMType = "Microsoft.ConnectedVMwareVsphere/VirtualMachines"
$VMInstanceType = "Microsoft.ConnectedVMwareVsphere/VirtualMachineInstances"

$resourceTypes = [PSCustomObject]@(
  @{ Type = $VMType; InventoryType = "VirtualMachine" },
  @{ Type = $VMInstanceType; InventoryType = "VirtualMachine"; AzSubCommand = "vm" },
  @{ Type = "Microsoft.ConnectedVMwareVsphere/VirtualMachineTemplates"; InventoryType = "VirtualMachineTemplate"; AzSubCommand = "vm-template" },
  @{ Type = "Microsoft.ConnectedVMwareVsphere/Hosts"; InventoryType = "Host"; AzSubCommand = "host" },
  @{ Type = "Microsoft.ConnectedVMwareVsphere/Clusters"; InventoryType = "Cluster"; AzSubCommand = "cluster" },
  @{ Type = "Microsoft.ConnectedVMwareVsphere/ResourcePools"; InventoryType = "ResourcePool"; AzSubCommand = "resource-pool" },
  @{ Type = "Microsoft.ConnectedVMwareVsphere/Datastores"; InventoryType = "Datastore"; AzSubCommand = "datastore" },
  @{ Type = "Microsoft.ConnectedVMwareVsphere/VirtualNetworks"; InventoryType = "VirtualNetwork"; AzSubCommand = "virtual-network" }
)

foreach ($resourceType in $resourceTypes) {
  $resourceIds = @()
  $skipToken = $null

  $resourcesQuery = ""
  if ($resourceType.Type -eq $VMInstanceType) {
    $resourcesQuery = @"
  ConnectedVMwareVsphereResources
  | where type =~ 'Microsoft.ConnectedVMwareVsphere/VirtualMachineInstances'
  | where properties.infrastructureProfile.vCenterId =~ '$vCenterId'
  | project id=tolower(id)
"@
  }
  else {
    $resourcesQuery = @"
  Resources
  | where type =~ '$($resourceType.Type)'
  | where properties.vCenterId =~ '$vCenterId'
  | project id=tolower(id)
"@
  }

  $query = @"
( 
  $resourcesQuery
  | union (
    ConnectedVMwareVsphereResources
    | where type =~ 'Microsoft.ConnectedVMwareVsphere/VCenters/InventoryItems' and kind =~ '$($resourceType.InventoryType)'
    | where id startswith '$vCenterId/InventoryItems'
    | where properties.managedResourceId != ''
    | extend id=tolower(tostring(properties.managedResourceId))
    | where id contains '/$($resourceType.InventoryType)/'
    | project id
  )
) | distinct id
"@.Replace("`r`n", " ").Replace("`n", " ")
  logText "Searching $($resourceType.Type)..."
  $deleteFailed = @()
  while ($true) {
    if ($skipToken) {
      $page = az graph query --skip-token $skipToken -q $query --debug 2>> $logFile | ConvertFrom-Json
    }
    else {
      $page = az graph query -q $query --debug 2>> $logFile | ConvertFrom-Json
    }
    $page.data | ForEach-Object {
      $resourceIds += $_.id
    }
    if ($null -eq $page.skip_token) {
      break
    }
    $skipToken = $page.skip_token
  }
  logText "Found $($resourceIds.Count) $($resourceType.Type)"

  $azArgs = @()
  if ($resourceType.Type -eq $VMInstanceType) {
    $azArgs += "--delete-machine"
  }
  $width = $resourceIds.Count.ToString().Length
  for ($i = 0; $i -lt $resourceIds.Count; $i++) {
    $resourceId = $resourceIds[$i]
    logText $("({0,$width}/$($resourceIds.Count)) Deleting $resourceId" -f $($i + 1))
    if ($resourceType.Type -eq $VMType) {
      $urlParams = "?api-version=${VM_API_Version}"
      az rest --method delete --url "${resourceId}${urlParams}" --debug 2>> $logFile
    }
    else {
      az connectedvmware $resourceType.AzSubCommand delete --debug --yes --ids $resourceId @azArgs 2>> $logFile
    }
    if ($LASTEXITCODE -ne 0) {
      logText "Failed to delete $resourceId" -color Red
      $deleteFailed += $resourceId
    }
    if ($deleteFailed.Count -gt $DeleteFailedThreshold) {
      fail @"
  Failed to delete $($deleteFailed.Count) resources. Skipping the deletion of the rest of the resources in the vCenter.
  The resource ID of these resources are:
`t$($deleteFailed -join "`n`t")

  Skipping vCenter deletion.
"@
    }
  }
}

if ($deleteFailed.Count -gt 0) {
  fail @"
  Failed to delete $($deleteFailed.Count) resources. The resource ID of these resources are:
`t$($deleteFailed -join "`n`t")

  Skipping vCenter deletion.
"@
}

Write-Host ""
logText "Successfully deleted all the resources in the vCenter"
logText "Deleting the vCenter: $vCenterId"
$azArgs = @()
az connectedvmware vcenter delete --debug --yes --ids $vCenterId $azArgs 2>> $logFile
if ($LASTEXITCODE -ne 0) {
  if ($deleteFailed.Count -eq 0) {
    # Some resources are not found in ARM / ARG, but still exist in VMware DB.
    fail "Failed to delete $vCenterId even though all the resources accosiated with the vCenter were deleted successfully from ARM. Please reach out to arc-vmware-feedback@microsoft.com or create a support ticket for Arc enabled VMware vSphere in Azure portal."
  }
  else {
    fail "Failed to delete $vCenterId"
  }
}
if ($PSBoundParameters.ContainsKey('AVSId')) {
  logText "Deleting the arc addon for the AVS $AVSId"
  az rest --method delete --debug --url "$AVSId/addons/arc?api-version=$AVS_API_Version" 2>> $logFile
  if ($LASTEXITCODE -ne 0) {
    fail "Failed to delete $AVSId/addons/arc"
  }
}

logText "Cleanup Complete!"
