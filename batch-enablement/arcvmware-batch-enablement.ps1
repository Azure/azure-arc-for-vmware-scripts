<#
.SYNOPSIS
This is a helper script for enabling VMs in a vCenter in batch. The script will create the following files:
  arcvmware-batch-enablement.log - log file
  deployments-<timestamp>/all-deployments-<timestamp>.txt - list of Azure portal links to all deployments created
  deployments-<timestamp>/vmw-dep-<timestamp>-<batch>.json - ARM deployment files
  deployments-<timestamp>/all-summary.csv - summary of the VMs enabled
  last-run.csv - history of attempts to enable in azure and install guest management on VMs

Before running this script, please install az cli and the extensions: connectedvmware and resource-graph.
az extension add --name connectedvmware
az extension add --name resource-graph

.PARAMETER VCenterId
The ARM ID of the vCenter where the VMs are located. For example: /subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter

.PARAMETER VMInventoryFile
The path to the VM Inventory file. This file should be generated using the export-vcenter-vms.ps1 script, and filtered as needed. The file can be in CSV or JSON format. The format will be auto-detected using the file extension. All the VMs in the file which have VMware Tools running will be enabled. If this file is not specified, we try to enable and install GM on all VMs which are powered on and have VMware Tools running.

.PARAMETER SubscriptionId
The target subscription ID where the VMs will be enabled. If not specified, the script will use the subscription ID from the VCenterId.

.PARAMETER ResourceGroup
The target resource group where the VMs will be enabled. If not specified, the script will use the resource group from the VCenterId.

.PARAMETER EnableGuestManagement
If this switch is specified, the script will enable guest management on the VMs. If not specified, guest management will not be enabled.

.PARAMETER VMCredential
The credentials to be used for enabling guest management on the VMs. If not specified, the script will prompt for the credentials.

.PARAMETER VMCredsFile
If UseSavedCredentials is used, by default the script will read the VM credentials from `.do-not-reveal-vm-credentials.xml` file in the script directory. If you want to use a different file, you can specify the file path using this parameter.

.PARAMETER UseSavedCredentials
If this switch is specified, the script will use the saved credentials from the last run. If not specified, the script will prompt for the credentials. This is useful when you are running the script as a cronjob.

.PARAMETER Execute
If this switch is specified, the script will deploy the created ARM templates. If not specified, the script will only create the ARM templates and provide the summary.

.PARAMETER UseDiscoveredInventory
By default, if the VM Inventory File is not provided, the script generates the VM Inventory file by running azure resource graph query. The exported inventory VM data (CSV or JSON) can be filtered and split into multiple files as per the requirement. For each file, we'll use a single user account to enable the VMs to Arc. If this switch is specified, the script will use the generated VM inventory file for enabling the VMs and guest management. This param cannot be specified along with VMInventoryFile.

.PARAMETER ARGFilter
The filter to be used in the ARG query to filter the VMs. This is an advanced parameter and should be used with caution. Make sure to check the generated inventory file before running with -Execute switch. This parameter is useful when you want to run a cronjob with -UseDiscoveredInventory switch, and you want to filter the VMs based on some criteria. For sample filters, refer to the 'Advanced Cron Job' section in the README.


.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement

This command will generate the VM Inventory file, and exit.

.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement -UseDiscoveredInventory

This command will generate the VM Inventory file, and use this inventory to generate the ARM templates. But it will not deploy the ARM templates.

.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement -UseDiscoveredInventory -Execute

This command will enable all VMs in the vCenter specified in the VCenterId parameter. It will also enable guest management on the VMs. The script will deploy the created ARM templates.

.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement -UseDiscoveredInventory -UseSavedCredentials -Execute

This command will enable all VMs in the vCenter specified in the VCenterId parameter. It will also enable guest management on the VMs. The script will use the saved credentials from the last run. It will deploy the created ARM templates.

.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter"  -EnableGuestManagement -VMInventoryFile "vms.csv" -VMCredsFile "vm-creds.xml" -Execute

This command will enable all VMs in the vCenter specified in the VCenterId parameter. It will also enable guest management on the VMs. The script will read the list of VMs from the VMInventoryFile and deploy the created ARM templates. It will use the credentials from the VMCredsFile.

.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -VMInventoryFile "vms.csv" -EnableGuestManagement -Execute

This command will enable all VMs in the vCenter specified in the VCenterId parameter. It will also enable guest management on the VMs. The script will read the list of VMs from the VMInventoryFile and deploy the created ARM templates.

.EXAMPLE
.\arcvmware-batch-enablement.ps1 -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement -UseDiscoveredInventory -UseSavedCredentials -ARGFilter "| where osName contains 'Windows' and toolsVersion > 11365 and ipAddresses hasprefix '172.'"

#>
param(
  [Parameter(Mandatory = $true)]
  [string]$VCenterId,
  [string]$VMInventoryFile,
  [string]$SubscriptionId,
  [string]$ResourceGroup,
  [switch]$EnableGuestManagement,
  [string]$ProxyUrl,
  [string]$ARGFilter,
  [PSCredential]$VMCredential,
  [string]$VMCredsFile,
  [switch]$UseSavedCredentials,
  [switch]$Execute,
  [switch]$UseDiscoveredInventory
)

# https://stackoverflow.com/a/40098904/7625884
$PSDefaultParameterValues = @{ '*:Encoding' = 'utf8' }

Write-Host "Setting the TLS Protocol for the current session to TLS 1.3 if supported, else TLS 1.2."
# Ensure TLS 1.2 is accepted. Older PowerShell builds (sometimes) complain about the enum "Tls12" so we use the underlying value
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
# Ensure TLS 1.3 is accepted, if this .NET supports it (older versions don't)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 12288 } catch {}

$VCenterIdFormat = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter"

$VMWARE_RP_NAMESPACE = "Microsoft.ConnectedVMwarevSphere"

$ARGPortalBlade = "https://portal.azure.com/#view/HubsExtension/ArgQueryBlade"

function Get-TimeStamp {
  return (Get-Date).ToUniversalTime().ToString("[yyyy-MM-ddTHH:mm:ss.fffZ]")
}

$StartTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ss")

$logFile = Join-Path $PSScriptRoot -ChildPath "arcvmware-batch-enablement.log"
$deploymentFolderPath = Join-Path $PSScriptRoot -ChildPath "deployments-$StartTime"
$deploymentUrlsFilePath = Join-Path $deploymentFolderPath -ChildPath "all-deployments.txt"
$deploymentSummaryFilePath = Join-Path $deploymentFolderPath -ChildPath "all-summary.csv"
$azDebugLog = Join-Path $deploymentFolderPath -ChildPath "az-debug.log"
$defaultVMCredsPath = Join-Path $deploymentFolderPath -ChildPath ".do-not-reveal-vm-credentials.xml"
$ARGQueryDumpFile = Join-Path $deploymentFolderPath -ChildPath "arg-query.kql"
# Inv2LastRunFile is used to store the history of guest management attempts.
# A VM which failed in an earlier attempt will not be attempted again unless the entry is deleted from this file.
$Inv2LastRunFile = Join-Path $PSScriptRoot -ChildPath "last-run.csv"
$SkippedCount = 0
$Inv2LastRun = @{}
function CreateDeploymentFolder {
  if (!(Test-Path $deploymentFolderPath)) {
    New-Item -ItemType Directory -Path $deploymentFolderPath | Out-Null
  }
}
function LogText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )
  Write-Host "$(Get-TimeStamp) $Text"
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) $Text"
}

function LogDebug {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) [Debug] $Text"
}

function LogError {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Text
  )
  Write-Error "$(Get-TimeStamp) $Text"
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) Error: $Text"
}

function LoadInv2LastRun {
  # Load the csv file.
  if (!(Test-Path $Inv2LastRunFile -PathType Leaf)) {
    LogDebug "Inv2LastRunFile not found: $Inv2LastRunFile"
    return
  }
  $table = Import-Csv -Path $Inv2LastRunFile
  for ($i = 0; $i -lt $table.Length; $i++) {
    $row = $table[$i]
    $Script:Inv2LastRun[$row.inventoryItemId] = $row
  }
  LogDebug "Loaded $($table.Length) entries from Inv2LastRunFile."
}
function SaveInv2LastRun {
  $table = @()
  foreach ($key in $Inv2LastRun.Keys) {
    $table += $Inv2LastRun[$key]
  }

  # Custom ordering of columns and sorting rows
  $table = $table | Select-Object moName, gmErrorCode, vmName, moRefId, correlationId, vCenterId, inventoryItemId, gmState, vmErrorCode, vmState, gmErrorMessage, vmErrorMessage
  $table = $table | Sort-Object -Property gmState, vmState, VCenterId, VMName, MoRefId

  $table | Export-Csv -Path $Inv2LastRunFile -NoTypeInformation
  $table | ConvertTo-Html | Out-File -FilePath ($Inv2LastRunFile -replace "\.csv$", ".html") -Encoding UTF8
}

if ($VMCredsFile) {
  $UseSavedCredentials = $true
}
elseif ($UseSavedCredentials) {
  $VMCredsFile = $defaultVMCredsPath
}
if ($VMCredential -or $UseSavedCredentials) {
  if (!$EnableGuestManagement) {
    LogText "EnableGuestManagement is implicitly set to true as credentials are provided."
    $EnableGuestManagement = $true
  }
}

function Get-ARMPartsFromID($id) {
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

#Region: ARM Template

# ARM Template part for VM Creation
$VMtpl = @{
  type       = "Microsoft.Resources/deployments"
  apiVersion = "2021-04-01"
  name       = "{{vmName}}-vm"
  properties = @{
    mode     = "Incremental"
    template = @{
      '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
      contentVersion = "1.0.0.0"
      resources      = @(
        @{
          type       = "Microsoft.HybridCompute/machines"
          apiVersion = "2023-03-15-preview"
          name       = "{{vmName}}"
          kind       = "VMware"
          location   = "{{location}}"
          properties = @{}
        }
        @{
          type             = "Microsoft.ConnectedVMwarevSphere/VirtualMachineInstances"
          apiVersion       = "2023-03-01-preview"
          name             = "default"
          scope            = "[concat('Microsoft.HybridCompute/machines', '/', '{{vmName}}')]"
          properties       = @{
            infrastructureProfile = @{
              inventoryItemId = "{{vCenterId}}/InventoryItems/{{moRefId}}"
            }
          }
          extendedLocation = @{
            type = "CustomLocation"
            name = "{{customLocationId}}"
          }
          dependsOn        = @(
            "[resourceId('Microsoft.HybridCompute/machines','{{vmName}}')]"
          )
        }
      )
    }
  }
}

# ARM Template part for Guest Management
$GMtpl = @{
  type       = "Microsoft.Resources/deployments"
  apiVersion = "2021-04-01"
  name       = "{{vmName}}-gm"
  dependsOn  = @(
    "[resourceId('Microsoft.Resources/deployments','{{vmName}}-vm')]"
  )
  properties = @{
    mode     = "Incremental"
    template = @{
      '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
      contentVersion = "1.0.0.0"
      resources      = @(
        @{
          type       = "Microsoft.HybridCompute/machines"
          apiVersion = "2023-03-15-preview"
          name       = "{{vmName}}"
          kind       = "VMware"
          location   = "{{location}}"
          properties = @{
          }
          identity   = @{
            type = "SystemAssigned"
          }
        }
        @{
          type       = "Microsoft.ConnectedVMwarevSphere/VirtualMachineInstances/guestAgents"
          apiVersion = "2023-03-01-preview"
          name       = "default/default"
          scope      = "[concat('Microsoft.HybridCompute/machines', '/', '{{vmName}}')]"
          properties = @{
            provisioningAction = "install"
            credentials        = @{
              username = "[parameters('guestManagementUsername')]"
              password = "[parameters('guestManagementPassword')]"
            }
            httpProxyConfig    = @{
              httpsProxy = "{{proxyUrl}}"
            }
          }
          dependsOn  = @(
            "[resourceId('Microsoft.HybridCompute/machines','{{vmName}}')]"
          )
        }
      )
    }
  }
}

$parametersTemplate = @{
  '$schema'      = "https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#"
  contentVersion = "1.0.0.0"
  parameters     = @{
    guestManagementUsername = @{
      value = ""
    }
    guestManagementPassword = @{
      value = ""
    }
  }
}

$deploymentTemplate = @{
  '$schema'      = "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#"
  contentVersion = "1.0.0.0"
  parameters     = @{
    guestManagementUsername = @{
      type = "string"
    }
    guestManagementPassword = @{
      type = "securestring"
    }
  }
  resources      = @()
}

#EndRegion: ARM Template

#StartRegion: ARG Query

if ($EnableGuestManagement) {
  $filterQuery = "`n" + "| where  virtualHardwareManagement in ('Enabled', 'Disabled') and guestAgentEnabled == 'No' and powerState == 'poweredon' and isnotempty(toolsRunningStatus) and toolsRunningStatus != 'Not running'"
  $filterQuery += "`n" + "| where osName !startswith 'VMware ' and osName !startswith 'Apple ' and osName !has 'CBL-Mariner' and osName !has 'FreeBSD' and osName !has 'NetBSD' and osName !has 'OpenBSD'"
}
else {
  # We do not include old resource type VMs and Link to vCenter VMs in the result.
  $filterQuery = "`n" + "| where  virtualHardwareManagement in ('Enabled', 'Disabled')"
}
if ($ARGFilter) {
  $filterQuery += "`n" + $ARGFilter
}

$argQuery = @"
connectedVMwarevSphereResources
| where type =~ 'microsoft.connectedvmwarevsphere/vcenters/inventoryitems' and kind =~ 'virtualmachine'
| where id startswith '${VCenterId}/InventoryItems'
| extend managedResourceId = tolower(tostring(properties.managedResourceId))
| extend moRefId = tostring(properties.moRefId)
| extend moName = tostring(properties.moName), powerState = tolower(tostring(properties.powerState))
| extend osName = tostring(properties.osName)
| extend osType = tostring(properties.osType)
| extend toolsRunningStatus = tostring(properties.toolsRunningStatus), toolsVersionStatus = tostring(properties.toolsVersionStatus)
| extend toolsVersion = tostring(properties.toolsVersion), host = tostring(properties.host.moName), cluster=tostring(properties.cluster.moName)
| extend resourcePool = tostring(properties.resourcePool.moName), ipAddresses = properties.ipAddresses
| extend inventoryType = kind
| extend indexOfVmInstance = indexof(managedResourceId, '/providers/microsoft.connectedvmwarevsphere/virtualmachineinstances/default')
| extend hasHcrp = indexof(managedResourceId, 'microsoft.hybridcompute/machines') > -1
| extend hasVmInstance = indexOfVmInstance > -1
| extend linkToVCenter = hasHcrp and not(hasVmInstance)
| extend isOldResourceModel = indexof(managedResourceId, 'microsoft.connectedvmwarevsphere/virtualmachines') > -1
| extend isNewResourceModel = hasHcrp and hasVmInstance
| extend hcrpId = iff(indexOfVmInstance > -1, substring(managedResourceId, 0, indexOfVmInstance), managedResourceId)
| join kind = leftouter (
    resources
        | where type in~ ('microsoft.hybridcompute/machines', 'microsoft.connectedvmwarevsphere/virtualmachines')
        | extend machineId = tolower(tostring(id))
        | extend agentVersion = iff(type =~ 'microsoft.hybridcompute/machines', properties.agentVersion, properties.guestAgentProfile.agentVersion)
    ) on `$left.hcrpId == `$right.machineId
| join kind = leftouter (
    connectedVMwarevSphereResources
        | where type =~ 'microsoft.connectedvmwarevsphere/virtualmachineinstances'
        | extend vpshereResourceId = tolower(tostring(id))
    ) on `$left.managedResourceId == `$right.vpshereResourceId
| extend guestAgentEnabled = iff(isnotempty(agentVersion), 'Yes', 'No')
| extend toolsRunningStatus = case(
    toolsRunningStatus =~ 'guestToolsExecutingScripts', 'Starting',
    toolsRunningStatus =~ 'guestToolsRunning', 'Running',
    toolsRunningStatus =~ 'guestToolsNotRunning', 'Not running',
    toolsRunningStatus)
| extend toolsVersionStatus = case(
    toolsVersionStatus =~ 'guestToolsUnmanaged', 'Guest managed',
    toolsVersionStatus in~ ('guestToolsBlacklisted', 'guestToolsTooNew', 'guestToolsTooOld'), 'Version unsupported',
    toolsVersionStatus in~ ('guestToolsCurrent', 'guestToolsSupportedNew'), 'Up to date',
    toolsVersionStatus in~ ('guestToolsNeedUpgrade', 'guestToolsSupportedOld'), 'Upgrade available',
    toolsVersionStatus =~ 'guestToolsNotInstalled', 'Not installed',
    toolsVersionStatus)
| extend toolsSummary = case(
    toolsVersionStatus =~ 'Not installed', toolsVersionStatus,
    isempty(toolsRunningStatus), 'Not installed',
    isempty(toolsVersion), toolsRunningStatus,
    isnotempty(toolsVersionStatus), strcat(toolsRunningStatus, ', ', 'Version', ': ', toolsVersion, ', ', '(', toolsVersionStatus, ')'),
    'Not installed')
| extend azureEnabled = iff(isnotempty(managedResourceId), 'Yes', 'No')
| extend virtualHardwareManagement = case(
    isnotempty(managedResourceId) and isOldResourceModel, 'Enabled (deprecated)',
    isnotempty(managedResourceId) and isNewResourceModel, 'Enabled',
    linkToVCenter, 'Link to vCenter',
    'Disabled')
| extend vmName = moName
| extend toolsVersion = toint(toolsVersion)${filterQuery}
| extend ipAddresses=tostring(ipAddresses)
| project id, moName, moRefId, inventoryType, azureEnabled, virtualHardwareManagement, guestAgentEnabled, powerState, toolsSummary, toolsRunningStatus, toolsVersionStatus, toolsVersion, osName, osType, ipAddresses, host, cluster, resourcePool, managedResourceId, resourceGroup, vmName
"@

#EndRegion: ARG Query

LogText @"
Starting script with the following parameters:
  VCenterId: $VCenterId
  EnableGuestManagement: $EnableGuestManagement
  VMInventoryFile: $VMInventoryFile
  VMCredential: $VMCredential
  VMCredsFile: $VMCredsFile
  SubscriptionId: $SubscriptionId
  ResourceGroup: $ResourceGroup
  ProxyUrl: $ProxyUrl
  ARGFilter: $ARGFilter
  Execute: $Execute
  UseSavedCredentials: $UseSavedCredentials
  UseDiscoveredInventory: $UseDiscoveredInventory
  LogFile: $logFile
"@

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
  LogError "az command is not found. Please install azure cli before running this script."
  exit
}

if ($UseDiscoveredInventory -and $VMInventoryFile) {
  LogError "UseDiscoveredInventory and VMInventoryFile cannot be specified together."
  exit
}

function ResolveVMCredsFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
  )
  if (Test-Path $FilePath -PathType Leaf) {
    return $FilePath
  }
  $FilePathRelToScript = Join-Path -Path $PSScriptRoot -ChildPath $FilePath
  if (Test-Path $FilePathRelToScript -PathType Leaf) {
    return $FilePathRelToScript
  }
  LogError "VM credentials file not found at: $FilePath"
  exit
}

if ($VMCredsFile) {
  $VMCredsFile = ResolveVMCredsFile -FilePath $VMCredsFile
  LogText "Using VM credentials file: $VMCredsFile"
  $VMCredential = Import-Clixml -Path $VMCredsFile
}

LogText "Installing or upgrading the required Azure CLI extensions"

if (!(az extension show --name connectedvmware -o json)) {
  az extension add --allow-preview false --upgrade --name connectedvmware
}

$vcInfo = Get-ARMPartsFromID $VCenterId
if (!$vcInfo) {
  LogError "Invalid VCenterId: $VCenterId . Expected format: $VCenterIdFormat"
  exit
}

$vCenterName = $vcInfo.Name
if (!$SubscriptionId) {
  $SubscriptionId = $vcInfo.SubscriptionId
}
if (!$ResourceGroup) {
  $ResourceGroup = $vcInfo.ResourceGroup
}

if ($vcInfo.Provider -ne "Microsoft.ConnectedVMwarevSphere") {
  LogError "Invalid VCenterId: $VCenterId . Expected format: $VCenterIdFormat"
  exit
}
if ($vcInfo.Type -ne "VCenters") {
  LogError "Invalid VCenterId: $VCenterId . Expected format: $VCenterIdFormat"
  exit
}

$vcPropsJson = az connectedvmware vcenter show --subscription $vcInfo.SubscriptionId --resource-group $vcInfo.ResourceGroup --name $vCenterName --query '{clId: extendedLocation.name, location:location}' -o json
if (!$vcPropsJson) {
  LogError "Failed to get vCenter properties for $vCenterName . Please make sure you have logged in to azure using 'az login'."
  exit
}
$vcenterProps = $vcPropsJson | ConvertFrom-Json
$customLocationId = $vcenterProps.clId
if (!$customLocationId) {
  LogError "Failed to extract custom location id from vCenter $vCenterName"
  exit
}
$location = $vcenterProps.location

LogText "Extracted custom location: $customLocationId"
LogText "Extracted location: $location"

if ($Execute) {
  LoadInv2LastRun
}

# if VMInventoryFile is not specified, we generate it
if (!$VMInventoryFile) {
  if (!(az extension show --name resource-graph -o json)) {
    az extension add --allow-preview false --upgrade --name resource-graph
  }

  if ($EnableGuestManagement) {
    LogText "Enabling and installing guest agent on the VMs which are powered on and have VMware Tools running."
  }
  else {
    LogText "Enabling the VMs which are not enabled in Azure."
  }

  $dumpFolder = $PSScriptRoot
  if ($UseDiscoveredInventory) {
    $dumpFolder = $deploymentFolderPath
    CreateDeploymentFolder
  }
  $OutFileCSV = Join-Path -Path $dumpFolder -ChildPath "vms.csv"
  $OutFileJSON = Join-Path -Path $dumpFolder -ChildPath "vms.json"
  $ARGQueryDumpFile = Join-Path $dumpFolder -ChildPath "arg-query.kql"
  # run arg query to get the VMs
  $skipToken = $null

  $query = $argQuery
  $query = $query.Replace("`r`n", " ").Replace("`n", " ")

  $argQuery = @"
// To get a list of the inventory data, you can run the query manually in the Azure Resource Graph Explorer:
// $ARGPortalBlade

"@ + $argQuery
  $argQuery | Out-File -FilePath $ARGQueryDumpFile -Encoding UTF8
  LogText "ARG query has been saved to $ARGQueryDumpFile . You can run the query manually at $ARGPortalBlade"
  LogText "Running resource graph query to generate the VM inventory file. This might take a while if you have a large number of VMs..."

  $vms = @()
  while ($true) {
    if ($skipToken) {
      $page = az graph query --skip-token $skipToken -q $query --debug 2>> $logFile | ConvertFrom-Json
    }
    else {
      $page = az graph query -q $query --debug 2>> $logFile | ConvertFrom-Json
      if (!$page) {
        $msg = "Failed to run the ARG query. Please check the log file for more details."
        if ($ARGFilter) {
          $msg += " Make sure the ARGFilter is correct. For verification, you can run the query present in the file $ARGQueryDumpFile manually at $ARGPortalBlade"
        }
        LogError $msg
        exit
      }
    }
    $page.data | ForEach-Object {
      $vms += $_
    }
    if ($null -eq $page.skip_token) {
      break
    }
    $skipToken = $page.skip_token
  }

  LogText "Found $($vms.Length) VMs in the vCenter inventory using ARG."
  $vms | ConvertTo-Json -Depth 30 | Out-File -FilePath $OutFileJSON -Encoding UTF8
  $vms | Export-Csv -Path $OutFileCSV -NoTypeInformation
  LogText "VM inventory saved to $OutFileJSON and $OutFileCSV."
  if (!$UseDiscoveredInventory) {
    LogText "Please review the inventory file, and filter and split into groups as needed. For each file, we'll use a single user account to install guest management. If you want to enable all the discovered VMs, please run the script with the -UseDiscoveredInventory switch."
    exit
  }
  LogText "Using the generated VM inventory file for enabling the VMs."
  $VMInventoryFile = $OutFileCSV
}

if (!(Test-Path $VMInventoryFile -PathType Leaf)) {
  LogError "VMInventoryFile not found: $VMInventoryFile"
  exit
}

$attemptedVMs = $null
if ($VMInventoryFile -match "\.csv$") {
  $attemptedVMs = Import-Csv -Path $VMInventoryFile
}
elseif ($VMInventoryFile -match "\.json$") {
  $attemptedVMs = Get-Content -Path $VMInventoryFile | ConvertFrom-Json
}
else {
  LogError "Invalid VMInventoryFile: $VMInventoryFile. Expected file format: CSV or JSON."
  exit
}

if (!$attemptedVMs) {
  if ($UseDiscoveredInventory) {
    LogError "No VMs (matching the criteria) found in the vCenter inventory using ARG."
  }
  else {
    LogError "No VMs found in the inventory file: $VMInventoryFile"
  }
  exit
}

LogText "Getting the VMs from the vCenter inventory in Azure using ARM API..."

$vmInventoryList = az connectedvmware vcenter inventory-item list --subscription $vcInfo.SubscriptionId --resource-group $vcInfo.ResourceGroup --vcenter $vCenterName --query '[?kind == `VirtualMachine`].{moRefId:moRefId, moName:moName, managedResourceId:managedResourceId}' -o json | ConvertFrom-Json

$moRefId2Inv = @{}
foreach ($vm in $vmInventoryList) {
  $moRefId2Inv[$vm.moRefId] = @{
    moName            = $vm.moName
    managedResourceId = $vm.managedResourceId
  }
}

LogText "Found $($vmInventoryList.Length) VMs in azure, will attempt on $(attemptedVMs.Length) VMs."

if ($EnableGuestManagement -and !$VMCredential) {
  $VMCredential = Get-Credential -Message "Enter the VM credentials for enabling guest management"
  $VMCredential | Export-Clixml -Path $VMCredsFile -NoClobber -Force -Encoding UTF8
}

$uniqueIdx = 0
$usedNames = @{}
function normalizeMoName() {
  param(
    [Parameter(Mandatory = $true)]
    [string]$name
  )
  $maxLen = 54
  # https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-reserved-resource-name
  $reservedWords = @(
    @{reserved = "microsoft"; replacement = "msft" },
    @{reserved = "windows"; replacement = "win" }
  )
  foreach ($word in $reservedWords) {
    $name = $name -replace $word.reserved, $word.replacement
  }
  $res = $name -replace "[^A-Za-z0-9-]", "-"
  $suffixLen = "-vm".Length # or "-gm".Length
  if ($res.Length + $suffixLen -gt $maxLen) {
    $res = $res.Substring(0, $maxLen - $suffixLen - 3) + "$uniqueIdx"
    $Script:uniqueIdx += 1
  }
  elseif ($usedNames.ContainsKey($res)) {
    $res = $res + "$uniqueIdx"
    $Script:uniqueIdx += 1
  }
  $usedNames[$res] = $true
  return $res
}

function getDeploymentId($deploymentName) {
  return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$deploymentName"
}

$armTemplateLimit = 800

$resources = @()
$resCountInDeployment = 0
$batch = 0

$summary = @()

for ($i = 0; $i -lt $attemptedVMs.Length; $i++) {

  $depId2Data = @{}
  # Check if $attemptedVMs[$i] has the required keys : moRefId and vmName, else skip
  $requiredKeys = @("moRefId", "vmName")
  $keysPresent = $true
  foreach ($key in $requiredKeys) {
    if (!$attemptedVMs[$i].PSObject.Properties[$key]) {
      LogText "[$($i+1) / $($attemptedVMs.Length)] Warning: VM at index $i does not have the required property: $key. Skipping this VM: $($attemptedVMs[$i] | ConvertTo-Json -Compress)"
      $keysPresent = $false
      break
    }
  }
  if (!$keysPresent) {
    continue
  }

  $moRefId = $attemptedVMs[$i].moRefId
  $inventoryItemId = "$VCenterId/InventoryItems/$moRefId"

  if (!$moRefId2Inv.ContainsKey($moRefId)) {
    LogDebug "[$($i+1) / $($attemptedVMs.Length)] Warning: VM with moRefId $moRefId not found in the vCenter inventory in azure. Skipping."
    $summary += [PSCustomObject] @{
      vmName              = "$($attemptedVMs[$i].vmName)"
      moRefId             = $moRefId
      arcEnableAttempted  = $false
      guestAgentAttempted = $false
    }
    continue
  }

  $inv = $moRefId2Inv[$moRefId]

  if ($Inv2LastRun.ContainsKey($inventoryItemId)) {
    $m = $Inv2LastRun[$inventoryItemId]
    if ($m.vmState -eq "Failed" -or $m.gmState -eq "Failed") {
      $errCode = $m.gmErrorCode
      if (!$errCode) {
        $errCode = $m.vmErrorCode
      }
      LogText "[$($i+1) / $($attemptedVMs.Length)] Skipping VM $($m.moName) (moRefID: $($m.moRefId)) since it had failed with '$($errCode)'. Please fix the issue, remove the entry from $Inv2LastRunFile and run the script to attempt on this VM again."
      $summary += [PSCustomObject] @{
        vmName              = "$($attemptedVMs[$i].vmName)"
        moRefId             = $moRefId
        arcEnableAttempted  = $false
        guestAgentAttempted = $false
      }
      $SkippedCount += 1
      continue
    }
  }

  $vmName = normalizeMoName $inv.moName
  $alreadyEnabled = $false

  if ($inv.managedResourceId) {
    if ($inv.managedResourceId.Contains($VMWARE_RP_NAMESPACE)) {
      $alreadyEnabled = $true
    }
    $resInfo = Get-ARMPartsFromID $inv.managedResourceId
    $vmName = $resInfo.Name
  }

  if (!$alreadyEnabled) {
    $vmResource = $VMtpl | ConvertTo-Json -Depth 30
    $vmResource = $vmResource `
      -replace "{{location}}", $location `
      -replace "{{vmName}}", $vmName `
      -replace "{{moRefId}}", $moRefId `
      -replace "{{vCenterId}}", $VCenterId `
      -replace "{{customLocationId}}", $customLocationId `
    | ConvertFrom-Json
    $resCountInDeployment += 2
    $resources += $vmResource
    $vmdepId = getDeploymentId $vmResource.name
    $depId2Data[$vmdepId] = @{
      inventoryItemId = $inventoryItemId
      vCenterId       = $VCenterId
      vmName          = $vmName
      moName          = $inv.moName
      moRefId         = $moRefId
      depType         = "vm"
    }
  }

  if ($EnableGuestManagement) {
    $gmResource = $GMtpl | ConvertTo-Json -Depth 30
    $gmResource = $gmResource `
      -replace "{{location}}", $location `
      -replace "{{vmName}}", $vmName `
    | ConvertFrom-Json
    
    if ($ProxyUrl) {
      $gmResource.properties.template.resources[1].properties.httpProxyConfig.httpsProxy = $ProxyUrl
    }
    else {
      $gmResource.properties.template.resources[1].properties.httpProxyConfig = @{}
    }

    if ($alreadyEnabled) {
      $gmResource.dependsOn = @()
    }
    $resCountInDeployment += 2
    $resources += $gmResource
    $gmdepId = getDeploymentId $gmResource.name
    $depId2Data[$gmdepId] = @{
      inventoryItemId = $inventoryItemId
      vCenterId       = $VCenterId
      vmName          = $vmName
      moName          = $inv.moName
      moRefId         = $moRefId
      depType         = "gm"
    }
  }

  $summary += [PSCustomObject] @{
    vmName              = $vmName
    moRefId             = $moRefId
    arcEnableAttempted  = !$alreadyEnabled
    guestAgentAttempted = $true
  }

  if (($resCountInDeployment + 4) -ge $armTemplateLimit -or ($i + 1) -eq $attemptedVMs.Length) {
    $deployment = $deploymentTemplate | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $deployment.resources = $resources

    CreateDeploymentFolder

    $deployArgs = @()
    if ($EnableGuestManagement) {
      $paramsPath = Join-Path $deploymentFolderPath -ChildPath ".do-not-reveal-guestvm-credential.json"
      $parametersTemplate.parameters.guestManagementUsername.value = $VMCredential.UserName
      $parametersTemplate.parameters.guestManagementPassword.value = $VMCredential.GetNetworkCredential().Password
      $parametersTemplate | ConvertTo-Json -Depth 10 | Out-File -FilePath $paramsPath -Encoding UTF8
      $deployArgs += @(
        "--parameters",
        "@$paramsPath"
      )
    }
    else {
      $deployment.parameters = @{}
    }

    $batch += 1
    $deploymentName = "vmw-dep-$StartTime-$batch"
    $deploymentFilePath = Join-Path $deploymentFolderPath -ChildPath "$deploymentName.json"

    $deployment `
    | ConvertTo-Json -Depth 30 `
    | Out-File -FilePath $deploymentFilePath -Encoding UTF8

    if ($Execute) {
      $deploymentId = getDeploymentId $deploymentName
      try {
        $deploymentIdEsc = [uri]::EscapeDataString($deploymentId)
        $deploymentUrl = "https://portal.azure.com/#view/HubsExtension/DeploymentDetailsBlade/~/overview/id/$deploymentIdEsc"
      }
      catch {
        $deploymentUrl = "https://portal.azure.com/#resource$($deploymentId)/overview"
      }
      Add-Content -Path $deploymentUrlsFilePath -Value $deploymentUrl

      LogText "(Batch $batch) Deploying $deploymentFilePath"
      LogText "(Batch $batch) You can track the deployment through azure portal using the following link: $deploymentUrl"

      az deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup --name $deploymentName --template-file $deploymentFilePath @deployArgs --debug *>> $azDebugLog

      $correlationId = az deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name $deploymentName --query 'properties.correlationId' -o tsv
      if (!$correlationId) {
        LogError "Deployment $deploymentName could not be submitted. Please check the log file for more details."
      }

      $dList = @()
      if ($correlationId) {
        $jmesFilter = "[?properties.correlationId=='$correlationId']"
        $deployments = az deployment group list --subscription $SubscriptionId --resource-group $ResourceGroup --query $jmesFilter -o json
        if (!$deployments) {
          LogError "Failed to get the deployment details for correlationId: $correlationId"
        }
        else {
          $dList = $deployments | ConvertFrom-Json
        }
      }
      for ($j = 0; $j -lt $dList.Length; $j++) {
        $dep = $dList[$j]
        $name = $dep.name
        if ($dep.id -eq $deploymentId) {
          continue
        }
        $errorCode = @()
        $errorMessage = @()
        if ($dep.properties.error) {
          $dep.properties.error.details | ForEach-Object {
            $errorCode += $_.code
            $errorMessage += $_.message
          }
        }
        $typ = $depId2Data[$dep.id].depType
        $depId2Data[$dep.id] += @{
          deploymentUrl         = $deploymentUrl
          correlationId         = $correlationId
          "$($typ)State"        = $dep.properties.provisioningState
          "$($typ)ErrorCode"    = $errorCode -join ", "
          "$($typ)ErrorMessage" = $errorMessage -join ", "
        }
      }
      foreach ($key in $depId2Data.Keys) {
        $data = $depId2Data[$key]
        $invId = $data.inventoryItemId
        if (!$Inv2LastRun.ContainsKey($invId)) {
          $Inv2LastRun[$invId] = @{}
        }
        foreach ($k in $data.Keys) {
          if ($k -eq "depType") {
            continue
          }
          $Inv2LastRun[$invId][$k] = $data[$k]
        }
      }
      SaveInv2LastRun
    }
    $resources = @()

    $summary | Export-Csv -Path $deploymentSummaryFilePath -NoTypeInformation -Append
    $summary = @()
    $resCountInDeployment = 0

    # NOTE: set sleep time between deployments here, if needed.
    LogText "Sleeping for 5 seconds before running next batch"
    Start-Sleep -Seconds 5
  }
}

if (!$Execute) {
  LogText "The ARM templates have been created in the folder: $deploymentFolderPath"
  LogText "Please review the ARM templates and summary file before running the script with the -Execute switch."
  LogText "The summary file is saved at: $deploymentSummaryFilePath"
  LogText "The deployment URLs are saved at: $deploymentUrlsFilePath"
}

if ($Inv2LastRun.Count -gt 0) {
  LogText "Saved the history of guest management attempts to $Inv2LastRunFile"
  LogText "You can also open the html file $($Inv2LastRunFile -replace "\.csv$", ".html") in a web browser."
  LogText "Any failed VMs will not be attempted again unless the entry is deleted from the file $Inv2LastRunFile"
}
