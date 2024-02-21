<#
.SYNOPSIS
This is a helper script for enabling VMs in a vCenter in batch. The script will create the following files:
  vmware-batch.log - log file
  all-deployments-<timestamp>.txt - list of Azure portal links to all deployments created
  vmw-dep-<timestamp>-<batch>.json - ARM deployment files
  vmw-dep-summary.csv - summary of the VMs enabled

Before running this script, please install az cli and the connectedvmware extension.
az extension add --name connectedvmware

The script can be run as a cronjob to enable all VMs in a vCenter.
You can use a service principal for authenticating to azure for this automation. Please refer to the following documentation for more details:
https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal
Then, you can login to azure using the service principal using the following command:
az login --service-principal --username <clientId> --password <clientSecret> --tenant <tenantId>

Following is a sample powershell script to run the script as a cronjob:

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-File "C:\Path\To\vmware-batch-enable.ps1" -VCenterId "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter" -EnableGuestManagement -Execute' # Adjust the parameters as needed
$trigger = New-ScheduledTaskTrigger -Daily -At 3am  # Adjust the schedule as needed

Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "EnableVMs"

To unregister the task, run the following command:
Unregister-ScheduledTask -TaskName "EnableVMs"

.PARAMETER VCenterId
The ARM ID of the vCenter where the VMs are located. For example: /subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter

.PARAMETER VMInventoryFile
The path to the VM Inventory file. This file should be generated using the export-vcenter-vms.ps1 script, and filtered as needed. The file can be in CSV or JSON format. The format will be auto-detected using the file extension. All the VMs in the file which have VMware Tools running will be enabled.

.PARAMETER SubscriptionId
The target subscription ID where the VMs will be enabled. If not specified, the script will use the subscription ID from the VCenterId.

.PARAMETER ResourceGroup
The target resource group where the VMs will be enabled. If not specified, the script will use the resource group from the VCenterId.

.PARAMETER EnableGuestManagement
If this switch is specified, the script will enable guest management on the VMs. If not specified, guest management will not be enabled.

.PARAMETER VMCredential
The credentials to be used for enabling guest management on the VMs. If not specified, the script will prompt for the credentials.

.PARAMETER Execute
If this switch is specified, the script will deploy the created ARM templates. If not specified, the script will only create the ARM templates and provide the summary.

#>
param(
  [Parameter(Mandatory=$true)]
  [string]$VCenterId,
  [Parameter(Mandatory=$true)]
  [string]$VMInventoryFile,
  [string]$SubscriptionId,
  [string]$ResourceGroup,
  [switch]$EnableGuestManagement,
  [int]$VMCountPerDeployment,
  [PSCredential]$VMCredential,
  [switch]$Execute
)

$logFile = Join-Path $PSScriptRoot -ChildPath "arcvmware-batch-enablement.log"
$azDebugLog = Join-Path $PSScriptRoot -ChildPath "vmw-az-debug.log"

# https://stackoverflow.com/a/40098904/7625884
$PSDefaultParameterValues = @{ '*:Encoding' = 'utf8' }

Write-Host "Setting the TLS Protocol for the current session to TLS 1.3 if supported, else TLS 1.2."
# Ensure TLS 1.2 is accepted. Older PowerShell builds (sometimes) complain about the enum "Tls12" so we use the underlying value
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
# Ensure TLS 1.3 is accepted, if this .NET supports it (older versions don't)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 12288 } catch {}

$VCenterIdFormat = "/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter"

$VMWARE_RP_NAMESPACE = "Microsoft.ConnectedVMwarevSphere"

function Get-TimeStamp {
  return (Get-Date).ToUniversalTime().ToString("[yyyy-MM-ddTHH:mm:ss.fffZ]")
}

$StartTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ss")

$deploymentUrlsFilePath = Join-Path $PSScriptRoot -ChildPath "all-deployments-$StartTime.txt"

function LogText {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Text
  )
  Write-Host "$(Get-TimeStamp) $Text"
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) $Text"
}

function LogDebug {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Text
  )
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) [Debug] $Text"
}

function LogError {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Text
  )
  Write-Error "$(Get-TimeStamp) $Text"
  Add-Content -Path $logFile -Value "$(Get-TimeStamp) Error: $Text"
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
          # identity   = @{
          #   type = "SystemAssigned"
          # }
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
  parameters = @{
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
  parameters = @{
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

LogText @"
Starting script with the following parameters:
  VCenterId: $VCenterId
  EnableGuestManagement: $EnableGuestManagement
  VMInventoryFile: $VMInventoryFile
  VMCredential: $VMCredential
  Execute: $Execute
"@

if (!(Test-Path $VMInventoryFile -PathType Leaf)) {
  LogError "VMInventoryFile not found: $VMInventoryFile"
  exit
}

$attemptedVMs = $null
if ($VMInventoryFile -match "\.csv$") {
  $attemptedVMs = Import-Csv -Path $VMInventoryFile
} elseif ($VMInventoryFile -match "\.json$") {
  $attemptedVMs = Get-Content -Path $VMInventoryFile | ConvertFrom-Json
} else {
  LogError "Invalid VMInventoryFile: $VMInventoryFile. Expected file format: CSV or JSON."
  exit
}

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
  LogError "az command is not found. Please install azure cli before running this script."
  exit
}

if (!(az extension show --name connectedvmware -o json)) {
  LogError "The Azure CLI extension connectedvmware is not installed. Please run 'az extension add --name connectedvmware' before running this script."
  exit
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

$vcenterProps = az connectedvmware vcenter show --subscription $vcInfo.SubscriptionId --resource-group $vcInfo.ResourceGroup --name $vCenterName --query '{clId: extendedLocation.name, location:location}' -o json | ConvertFrom-Json
$customLocationId = $vcenterProps.clId
if (!$customLocationId) {
  LogError "Failed to extract custom location id from vCenter $vCenterName"
  exit
}
$location = $vcenterProps.location

LogText "Extracted custom location: $customLocationId"
LogText "Extracted location: $location"

$vmInventoryList = az connectedvmware vcenter inventory-item list --subscription $vcInfo.SubscriptionId --resource-group $vcInfo.ResourceGroup --vcenter $vCenterName --query '[?kind == `VirtualMachine`].{moRefId:moRefId, moName:moName, managedResourceId:managedResourceId}' -o json | ConvertFrom-Json

$moRefId2Inv = @{}
foreach ($vm in $vmInventoryList) {
  $moRefId2Inv[$vm.moRefId] = @{
    moName = $vm.moName
    managedResourceId = $vm.managedResourceId
  }
}

LogText "Found $($attemptedVMs.Length) VMs in the inventory file."
LogText "Found $($vmInventoryList.Length) VMs in the vCenter inventory, will only enable those which are present in the inventory file."

if ($EnableGuestManagement -and !$VMCredential) {
  $VMCredential = Get-Credential -Message "Enter the VM credentials for enabling guest management"
}

$uniqueIdx = 0

function normalizeMoName() {
  param(
    [Parameter(Mandatory=$true)]
    [string]$name
  )
  # https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-reserved-resource-name
  $reservedWords = @(
    @{reserved = "microsoft"; replacement = "msft"},
    @{reserved = "windows"; replacement = "win"}
  )
  foreach ($word in $reservedWords) {
    $name = $name -replace $word.reserved, $word.replacement
  }
  $res = $name -replace "[^A-Za-z0-9-]", "-"
  $suffixLen = "-vm".Length # or "-gm".Length
  if ($res.Length + $suffixLen -gt 64) {
    $res = $res.Substring(0, 64 - $suffixLen - 3) + "$uniqueIdx"
    $Script:uniqueIdx += 1
  }
  return $res
}

$armTemplateLimit = 800

$resources = @()
$resCountInDeployment = 0
$batch = 0

$summary = @()

for ($i = 0; $i -lt $attemptedVMs.Length; $i++) {

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

  if (!$moRefId2Inv.ContainsKey($moRefId)) {
    LogDebug "[$($i+1) / $($attemptedVMs.Length)] Warning: VM with moRefId $moRefId not found in the vCenter inventory in azure. Skipping."
    $summary += [PSCustomObject] @{
      vmName     = "$($attemptedVMs[$i].vmName)"
      moRefId    = $moRefId
      enabled    = $false
      guestAgent = $false
    }
    continue
  }

  $inv = $moRefId2Inv[$moRefId]

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
  }

  if ($EnableGuestManagement) {
    $gmResource = $GMtpl | ConvertTo-Json -Depth 30
    $gmResource = $gmResource `
      -replace "{{location}}", $location `
      -replace "{{vmName}}", $vmName `
      | ConvertFrom-Json

    if ($alreadyEnabled) {
      $gmResource.dependsOn = @()
    }
    $resCountInDeployment += 2
    $resources += $gmResource
  }

  $summary += [PSCustomObject] @{
    vmName = $vmName
    moRefId = $moRefId
    enabled = !$alreadyEnabled
    guestAgent = $true
  }

  if (($resCountInDeployment + 4) -ge $armTemplateLimit -or ($i + 1) -eq $attemptedVMs.Length) {
    $deployment = $deploymentTemplate | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $deployment.resources = $resources

    $deployArgs = @()
    if ($EnableGuestManagement) {
      $paramsPath = Join-Path $PSScriptRoot -ChildPath ".do-not-reveal-guestvm-credential.json"
      $parametersTemplate.parameters.guestManagementUsername.value = $VMCredential.UserName
      $parametersTemplate.parameters.guestManagementPassword.value = $VMCredential.GetNetworkCredential().Password
      $parametersTemplate | ConvertTo-Json -Depth 10 | Out-File -FilePath $paramsPath -Encoding UTF8
      $deployArgs += @(
        "--parameters",
        "@$paramsPath"
      )
    } else {
      $deployment.parameters = @{}
    }

    $batch += 1
    $deploymentName = "vmw-dep-$StartTime-$batch"
    $deploymentFilePath = Join-Path $PSScriptRoot -ChildPath "$deploymentName.json"

    $deployment `
    | ConvertTo-Json -Depth 30 `
    | Out-File -FilePath $deploymentFilePath -Encoding UTF8

    if ($Execute) {
      $deploymentId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$deploymentName"
      $deploymentUrl = "https://portal.azure.com/#resource$($deploymentId)/overview"
      Add-Content -Path $deploymentUrlsFilePath -Value $deploymentUrl

      LogText "(Batch $batch) Deploying $deploymentFilePath"

      az deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup --name $deploymentName --template-file $deploymentFilePath @deployArgs --debug *>> $azDebugLog
    }
    $resources = @()

    # NOTE: set sleep time between deployments here, if needed.
    LogText "Sleeping for 5 seconds before running next batch"
    Start-Sleep -Seconds 5
  }
}

$summary | Export-Csv -Path "$PSScriptRoot\vmw-dep-summary.csv" -NoTypeInformation
