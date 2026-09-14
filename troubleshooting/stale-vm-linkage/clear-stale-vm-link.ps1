<#
.SYNOPSIS
    Clears a stale inventory-link on an Arc-enabled VMware vSphere VM (vCenter inventory view shows "Action Needed").

.DESCRIPTION
    This script finds the inventory item, works out which Azure resources are missing, recreates the missing
    placeholder resources, then deletes the Arc VM so the delete clears the stale link.
    Uses Azure CLI commands, including 'az rest' to recreate missing placeholder resources.
    Nothing in VMware vCenter is created, modified or deleted by this script.

.EXAMPLE
    .\clear-stale-vm-link.ps1 -VCenterSubscriptionId "0000...." -VCenterName "my-vcenter" `
        -VCenterResourceGroup "rg-vcenter" -VmName "my-vm" -CheckOnly
#>

# Script parameters - everything the operator needs to supply for one VM.
param(
    # Azure subscription that holds the vCenter resource.
    [Parameter(Mandatory = $true)][string]$VCenterSubscriptionId,

    # Name of the Microsoft.ConnectedVMwarevSphere/VCenters resource in Azure.
    [Parameter(Mandatory = $true)][string]$VCenterName,

    # Resource group that holds the vCenter resource.
    [Parameter(Mandatory = $true)][string]$VCenterResourceGroup,

    # The VM name as it appears in vCenter (this is the inventory item "moName").
    [Parameter(Mandatory = $true)][string]$VmName,

    # Run every read-only check but skip all create/delete calls - use this to inspect first.
    [Parameter(Mandatory = $false)][switch]$CheckOnly
)

# Stop the script on the first unhandled error so we never continue on bad data.
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Step 0. Confirm the Azure CLI is available and point it at the vCenter's subscription.
# ---------------------------------------------------------------------------

# Write a banner so the log is easy to read.
Write-Host "=== Step 0: checking Azure CLI ===" -ForegroundColor Cyan

# Fail early with a clear message if the az CLI is not installed or not on PATH.
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI ('az') was not found on PATH." }

# Set the active subscription so the inventory/vCenter lookups target the right place.
az account set --subscription $VCenterSubscriptionId | Out-Null

# Confirm to the operator which subscription is now active.
Write-Host "Using subscription: $VCenterSubscriptionId"

# ---------------------------------------------------------------------------
# Step 1.1. Find the inventory item for this VM and read its managedResourceId.
# ---------------------------------------------------------------------------

# Banner for step 1.
Write-Host "`n=== Step 1: reading the vCenter inventory item for '$VmName' ===" -ForegroundColor Cyan

# List inventory items for the vCenter, filtered server-side to the VM we care about.
$inventoryJson = az connectedvmware vcenter inventory-item list `
    --resource-group $VCenterResourceGroup `
    --vcenter $VCenterName `
    --subscription $VCenterSubscriptionId `
    --query "[?moName=='$VmName']" -o json

# Convert the JSON array returned by the CLI into PowerShell objects.
$inventoryItems = @($inventoryJson | ConvertFrom-Json)

# If nothing came back, the VM name does not match any inventory item - stop.
if ($inventoryItems.Count -eq 0) { throw "No inventory item found with moName '$VmName' in vCenter '$VCenterName'." }

# If more than one matched, the name is ambiguous and we must not guess which one to fix.
if ($inventoryItems.Count -gt 1) { throw "Found $($inventoryItems.Count) inventory items named '$VmName'. Resolve manually." }

# Take the single matching inventory item.
$inventoryItem = $inventoryItems[0]

# The full ARM ID of the inventory item - passed to 'vm create' as --inventory-item.
$inventoryItemId = $inventoryItem.id

# The pointer we are trying to clear - the ARM ID the inventory item is linked to.
$managedResourceId = $inventoryItem.managedResourceId

# Show the operator what was found.
Write-Host "Inventory item id  : $inventoryItemId"
Write-Host "managedResourceId  : '$managedResourceId'"

# ---------------------------------------------------------------------------
# Step 1.2. Decide whether there is actually a stale link to clear.
# ---------------------------------------------------------------------------

# An empty managedResourceId means the VM is simply not Arc-enabled - there is nothing to fix.
if ([string]::IsNullOrWhiteSpace($managedResourceId)) {
    # Tell the operator and exit successfully.
    Write-Host "`nmanagedResourceId is already empty - no stale link. Nothing to do." -ForegroundColor Green
    return
}

# Pull the subscription id out of the stale ID - the placeholder must be recreated here.
$machineSubscriptionId = [regex]::Match($managedResourceId, '(?i)/subscriptions/([^/]+)').Groups[1].Value

# Pull the resource group out of the stale ID - the placeholder must be recreated here.
$machineResourceGroup = [regex]::Match($managedResourceId, '(?i)/resourceGroups/([^/]+)').Groups[1].Value

# Pull the HCRP machine name out of the stale ID - the placeholder must reuse this exact name.
$machineName = [regex]::Match($managedResourceId, '(?i)/machines/([^/]+)').Groups[1].Value

# If any of the three could not be parsed, the ID is not in a shape this script understands.
if (-not $machineSubscriptionId -or -not $machineResourceGroup -or -not $machineName) { throw "Could not parse subscription/resource group/machine name from managedResourceId: $managedResourceId" }

# Rebuild the canonical machine ARM ID from the parsed pieces so later calls are consistent.
$machineId = "/subscriptions/$machineSubscriptionId/resourceGroups/$machineResourceGroup/providers/Microsoft.HybridCompute/machines/$machineName"

# Show the names that must be matched exactly - a mismatch here is the usual reason the fix fails.
Write-Host "Linked machine     : $machineName (sub $machineSubscriptionId, rg $machineResourceGroup)"

# ---------------------------------------------------------------------------
# Step 1.3. Check whether the HCRP (Arc) machine still exists.
# ---------------------------------------------------------------------------

# Try to read the Arc machine; suppress output because we only care whether the call succeeded.
az connectedmachine show --ids $machineId -o none 2>$null

# $LASTEXITCODE is 0 when the machine exists, non-zero when it is gone (ResourceNotFound).
$machineExists = ($LASTEXITCODE -eq 0)

# Report which branch of the TSG we are on.
Write-Host "HCRP machine exists: $machineExists"

# ---------------------------------------------------------------------------
# Step 1.4. Read the custom location and region off the vCenter.
# ---------------------------------------------------------------------------

# Read the values needed to recreate the placeholder resources.
$vCenterDetailsJson = az connectedvmware vcenter show `
    --name $VCenterName `
    --resource-group $VCenterResourceGroup `
    --subscription $VCenterSubscriptionId `
    --query "{customLocationId:extendedLocation.name, location:location}" -o json

$vCenterDetails = $vCenterDetailsJson | ConvertFrom-Json
$customLocationId = $vCenterDetails.customLocationId
$location = $vCenterDetails.location

# Without a custom location the resource bridge is broken and nothing below will work.
if ([string]::IsNullOrWhiteSpace($customLocationId)) { throw "Could not read extendedLocation.name from vCenter '$VCenterName'. The resource bridge may be broken." }
if ([string]::IsNullOrWhiteSpace($location)) { throw "Could not read location from vCenter '$VCenterName'." }

# Show the values that will be stamped on the recreated resources.
Write-Host "Custom location    : $customLocationId"
Write-Host "Location           : $location"

# ---------------------------------------------------------------------------
# Step 2.1. Check whether the virtualMachineInstance ('default') exists.
# ---------------------------------------------------------------------------

# Only bother checking the child resource if the parent machine actually exists.
if ($machineExists) {
    # 'vm show' reads the virtualMachineInstance under the HCRP machine; a 404 means it is missing.
    az connectedvmware vm show `
        --resource-group $machineResourceGroup `
        --name $machineName `
        --subscription $machineSubscriptionId -o none 2>$null

    # Record whether the read succeeded.
    $vmInstanceExists = ($LASTEXITCODE -eq 0)
} else {
    # If the machine is gone, its child resource cannot exist either.
    $vmInstanceExists = $false
}

# Report the state of the child resource.
Write-Host "VM instance exists : $vmInstanceExists"

# In check-only mode, stop here before anything is created or deleted.
if ($CheckOnly) {
    # Remind the operator that no changes were made.
    Write-Host "`n-CheckOnly was specified - no resources were created or deleted." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Step 2.2 / 3.1. Recreate the missing placeholder resources.
# ---------------------------------------------------------------------------

# If the HCRP machine is missing, recreate it first with the exact identity from managedResourceId.
if (-not $machineExists) {
    Write-Host "`n=== Step 3.1: recreating placeholder HCRP machine ===" -ForegroundColor Cyan

    $machineBody = @{
        location = $location
        kind = "VMware"
        properties = @{}
    } | ConvertTo-Json -Compress

    az rest `
        --method put `
        --uri "https://management.azure.com${machineId}?api-version=2025-02-19-preview" `
        --headers "Content-Type=application/json" `
        --body $machineBody `
        --output none

    Write-Host "Placeholder HCRP machine created."
}

# If the child resource is missing, recreate it explicitly under the HCRP machine.
if (-not $vmInstanceExists) {
    Write-Host "`n=== Step 2.2/3.1: recreating virtualMachineInstance ===" -ForegroundColor Cyan

    $vmInstanceBody = @{
        extendedLocation = @{
            type = "CustomLocation"
            name = $customLocationId
        }
        properties = @{
            infrastructureProfile = @{
                inventoryItemId = $inventoryItemId
            }
        }
    } | ConvertTo-Json -Depth 4 -Compress

    az rest `
        --method put `
        --uri "https://management.azure.com${machineId}/providers/Microsoft.ConnectedVMwarevSphere/virtualMachineInstances/default?api-version=2023-12-01" `
        --headers "Content-Type=application/json" `
        --body $vmInstanceBody `
        --output none

    Write-Host "virtualMachineInstance created."
}

# ---------------------------------------------------------------------------
# Step 2.3 / 3.2. Delete the Arc VM - this is what actually clears the stale link.
# ---------------------------------------------------------------------------

# Banner for the delete step.
Write-Host "`n=== Step 2.3/3.2: deleting the Arc VM (vCenter VM is NOT touched) ===" -ForegroundColor Cyan

# Delete the Arc-side resources using the names from the stale link; --yes skips the confirmation prompt.
az connectedvmware vm delete `
    --resource-group $machineResourceGroup `
    --name $machineName `
    --subscription $machineSubscriptionId `
    --yes -o none

# Confirm the delete call returned.
Write-Host "Delete completed."

# ---------------------------------------------------------------------------
# Step 4. Verify that managedResourceId is now empty.
# ---------------------------------------------------------------------------

# Banner for the verification step.
Write-Host "`n=== Step 4: verifying the inventory item ===" -ForegroundColor Cyan

# Re-run the same query as step 1.1 to read the current value of the pointer.
$verifyJson = az connectedvmware vcenter inventory-item list `
    --resource-group $VCenterResourceGroup `
    --vcenter $VCenterName `
    --subscription $VCenterSubscriptionId `
    --query "[?moName=='$VmName'].managedResourceId" -o json

# Convert the result (an array with at most one string) into PowerShell objects.
$verifyValue = @($verifyJson | ConvertFrom-Json)[0]

# An empty value means the stale link is gone and the VM can be Arc-enabled again.
if ([string]::IsNullOrWhiteSpace($verifyValue)) {
    # Report success.
    Write-Host "SUCCESS: managedResourceId is now empty - the stale link has been cleared." -ForegroundColor Green
} else {
    # Report failure and point at the most common cause (a name mismatch).
    Write-Host "WARNING: managedResourceId is still '$verifyValue'." -ForegroundColor Red
    Write-Host "Check that the recreated machine used the exact subscription/resource group/name from the stale ID." -ForegroundColor Red
}
