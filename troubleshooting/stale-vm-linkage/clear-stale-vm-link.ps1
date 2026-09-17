<#
.SYNOPSIS
    Clears a stale inventory-link on an Arc-enabled VMware vSphere VM (vCenter inventory view shows "Action Needed").

.DESCRIPTION
    This script finds the inventory item, works out which Azure resources are missing, recreates the missing
    placeholder resources, then deletes the Arc VM so the delete clears the stale link.
    Uses only 'az' CLI commands - no direct REST calls.
    Nothing in VMware vCenter is created, modified or deleted by this script.

.EXAMPLE
    .\clear-stale-vm-link.ps1 `
        -VCenterId "/subscriptions/0000..../resourceGroups/rg-vcenter/providers/Microsoft.ConnectedVMwarevSphere/vCenters/my-vcenter" `
        -VmName "my-vm" -CheckOnly
#>

# Script parameters - everything the operator needs to supply for one VM.
param(
    # Full ARM ID of the Microsoft.ConnectedVMwarevSphere/VCenters resource.
    [Parameter(Mandatory = $true)][string]$VCenterId,

    # The VM name as it appears in vCenter (this is the inventory item "moName").
    [Parameter(Mandatory = $true)][string]$VmName,

    # Run every read-only check but skip all create/delete calls - use this to inspect first.
    [Parameter(Mandatory = $false)][switch]$CheckOnly
)

# Stop the script on the first unhandled error so we never continue on bad data.
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Prerequisite. The Arc resource bridge must be running before anything else.
# ---------------------------------------------------------------------------

# Banner for the prerequisite check.
Write-Host "=== Prerequisite: Azure Arc resource bridge ===" -ForegroundColor Cyan

# Every step below depends on the bridge - inventory reads and the recreate/delete all go through it.
Write-Host "This script requires the Azure Arc resource bridge for this vCenter to be up and running." -ForegroundColor Yellow
Write-Host "If the bridge is offline, the inventory lookups and the recreate/delete steps will fail," -ForegroundColor Yellow
Write-Host "and the stale link will not be cleared." -ForegroundColor Yellow

# Make the operator confirm the bridge is healthy before we touch anything.
$bridgeConfirmation = Read-Host "`nIs the Azure Arc resource bridge up and running? (yes/no)"
if ($bridgeConfirmation -ne "yes") {
    Write-Host "Aborted - bring the resource bridge online, then re-run this script." -ForegroundColor Yellow
    return
}

# Parse the vCenter ARM ID into the values required by the Azure CLI commands.
$vCenterIdMatch = [regex]::Match(
    $VCenterId.TrimEnd('/'),
    '(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.ConnectedVMwarevSphere/vCenters/([^/]+)$'
)

if (-not $vCenterIdMatch.Success) {
    throw "Invalid vCenter resource ID: $VCenterId"
}

$VCenterSubscriptionId = $vCenterIdMatch.Groups[1].Value
$VCenterResourceGroup = $vCenterIdMatch.Groups[2].Value
$VCenterName = $vCenterIdMatch.Groups[3].Value

# Run an 'az' existence probe and tell "resource is missing" apart from a genuine failure.
# Only a not-found error returns $false; anything else (auth, RBAC, throttling, network) throws.
function Test-AzResourceExists {
    param(
        [Parameter(Mandatory = $true)][string[]]$AzArgs,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Capture stderr alongside stdout so the failure reason can be inspected.
    #
    # The '2>&1' merge is run inside a child scope that sets $ErrorActionPreference to 'Continue'.
    # Reason: this script runs with $ErrorActionPreference = 'Stop'. When a native command's stderr
    # is merged into the success stream, Windows PowerShell wraps every stderr line in a
    # NativeCommandError record, and under 'Stop' that record is thrown as a terminating error -
    # so the function dies before the exit code below is ever read. The Azure CLI writes harmless
    # chatter to stderr on successful calls (for example the Python "SyntaxWarning: invalid escape
    # sequence" emitted by the connectedvmware extension), which made a perfectly good GET look
    # like a failure. Relaxing the preference for this one call keeps the rest of the script strict
    # while letting the exit code - not the presence of stderr text - decide the outcome.
    $probeOutput = & { $ErrorActionPreference = 'Continue'; & az @AzArgs -o none 2>&1 }

    # Exit code 0 means the resource was read successfully, regardless of any stderr noise above.
    if ($LASTEXITCODE -eq 0) {
        # Surface the ignored stderr text at verbose level so the noise is still diagnosable.
        if ($probeOutput) { Write-Verbose "$Description succeeded (exit code 0); ignoring stderr output: $($probeOutput | Out-String)" }
        return $true
    }

    # Flatten the captured output into a single string for matching.
    $probeText = ($probeOutput | Out-String)

    # A not-found error is an expected outcome - report it as "does not exist".
    if ($probeText -match '(?i)ResourceNotFound|ParentResourceNotFound|\(NotFound\)|was not found|could not be found') { return $false }

    # Any other error means we cannot trust the result - stop instead of acting on bad state.
    throw "$Description failed with an unexpected error (exit code $LASTEXITCODE): $probeText"
}

# ---------------------------------------------------------------------------
# Step 0. Confirm the Azure CLI is available and point it at the vCenter's subscription.
# ---------------------------------------------------------------------------

# Write a banner so the log is easy to read.
Write-Host "=== Step 0: checking Azure CLI ===" -ForegroundColor Cyan

# Fail early with a clear message if the az CLI is not installed or not on PATH.
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI ('az') was not found on PATH." }

# Set the active subscription so the inventory/vCenter lookups target the right place.
az account set --subscription $VCenterSubscriptionId | Out-Null

# A failure here means the subscription is wrong or the session is not logged in - stop now.
if ($LASTEXITCODE -ne 0) { throw "Failed to set the active subscription to '$VCenterSubscriptionId'. Check 'az login' and the subscription id." }

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

# A failed list tells us nothing about the inventory - do not treat it as "no items found".
if ($LASTEXITCODE -ne 0) { throw "Failed to list inventory items for vCenter '$VCenterName' in rg '$VCenterResourceGroup'." }

# Convert the JSON array returned by the CLI into PowerShell objects.
$inventoryItems = @($inventoryJson | ConvertFrom-Json)

# If nothing came back, the VM name does not match any inventory item - stop.
if ($inventoryItems.Count -eq 0) { throw "No inventory item found with moName '$VmName' in vCenter '$VCenterName'." }

# If more than one matched, show each item and ask the operator which one to fix.
if ($inventoryItems.Count -gt 1) {
    Write-Host "Found $($inventoryItems.Count) inventory items named '$VmName':" -ForegroundColor Yellow
    for ($index = 0; $index -lt $inventoryItems.Count; $index++) {
        $candidate = $inventoryItems[$index]
        Write-Host "  $($index + 1): moName='$($candidate.moName)' name='$($candidate.name)' moRefId='$($candidate.moRefId)' kind='$($candidate.kind)' managedResourceId='$($candidate.managedResourceId)'"
    }
    Write-Host "`n0: Exit without selecting an inventory item"

    [int]$selection = -1
    do {
        $selectionInput = Read-Host "`nSelect the inventory item to use (0-$($inventoryItems.Count))"
        $selectionIsValid = [int]::TryParse($selectionInput, [ref]$selection) -and
            $selection -ge 0 -and $selection -le $inventoryItems.Count

        if (-not $selectionIsValid) {
            Write-Host "Enter a number from 0 to $($inventoryItems.Count)." -ForegroundColor Yellow
        }
    } until ($selectionIsValid)

    if ($selection -eq 0) {
        Write-Host "No inventory item selected. Exiting without making changes." -ForegroundColor Yellow
        return
    }

    $inventoryItems = @($inventoryItems[$selection - 1])
}

# Take the single matching inventory item.
$inventoryItem = $inventoryItems[0]

# The full ARM ID of the inventory item - passed to 'vm create' as --inventory-item.
$inventoryItemId = $inventoryItem.id

# The pointer we are trying to clear - the ARM ID the inventory item is linked to.
$managedResourceId = $inventoryItem.managedResourceId

# Show the operator what was found.
Write-Host "Inventory item id  : $inventoryItemId"
Write-Host "Inventory item     : moName='$($inventoryItem.moName)' name='$($inventoryItem.name)' moRefId='$($inventoryItem.moRefId)' kind='$($inventoryItem.kind)'"
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

# Try to read the Arc machine; a not-found means it is gone, any other error stops the script.
$machineExists = Test-AzResourceExists -AzArgs @("connectedmachine", "show", "--ids", $machineId) `
    -Description "Reading HCRP machine '$machineName'"

# Report which branch of the TSG we are on.
Write-Host "HCRP machine exists: $machineExists"

# The 'kind' on an existing machine decides whether a VM instance can be created under it.
$machineKind = $null
if ($machineExists) {
    $machineKind = az connectedmachine show --ids $machineId --query "kind" -o tsv

    # Without the kind we cannot tell whether the recreate in step 2.2 would be rejected.
    if ($LASTEXITCODE -ne 0) { throw "Failed to read the 'kind' property of HCRP machine '$machineName'." }

    # Show it - an empty or foreign kind is the usual reason 'vm create' fails with a 400.
    Write-Host "HCRP machine kind  : '$machineKind'"
}

# ---------------------------------------------------------------------------
# Step 1.4. Read the custom location off the vCenter (informational).
# ---------------------------------------------------------------------------

# 'az connectedvmware vm create' picks this up automatically, but we read it to fail early if it is missing.
# The vCenter 'kind' is read too: the service validates the machine kind against this exact value.
$vCenterJson = az connectedvmware vcenter show `
    --name $VCenterName `
    --resource-group $VCenterResourceGroup `
    --subscription $VCenterSubscriptionId `
    --query "{customLocation:extendedLocation.name, kind:kind}" -o json

# Distinguish "could not read the vCenter" from "the vCenter has no custom location".
if ($LASTEXITCODE -ne 0) { throw "Failed to read vCenter '$VCenterName' in rg '$VCenterResourceGroup'." }

# Convert the small projection into an object.
$vCenterInfo = $vCenterJson | ConvertFrom-Json

# The custom location that 'vm create' will stamp on the recreated resource.
$customLocationId = $vCenterInfo.customLocation

# The kind the HCRP machine must carry - 'VMware' normally, 'AVS' for an AVS-backed vCenter.
$expectedMachineKind = if ([string]::IsNullOrWhiteSpace($vCenterInfo.kind)) { "VMware" } else { $vCenterInfo.kind }

# Without a custom location the resource bridge is broken and nothing below will work.
if ([string]::IsNullOrWhiteSpace($customLocationId)) { throw "Could not read extendedLocation.name from vCenter '$VCenterName'. The resource bridge may be broken." }

# Show the custom location that 'vm create' will stamp on the recreated resource.
Write-Host "Custom location    : $customLocationId"
Write-Host "Expected kind      : $expectedMachineKind or empty"

# ---------------------------------------------------------------------------
# Step 2.1. Check whether the virtualMachineInstance ('default') exists.
# ---------------------------------------------------------------------------

# Only bother checking the child resource if the parent machine actually exists.
if ($machineExists) {
    # 'vm show' reads the virtualMachineInstance under the HCRP machine; a not-found means it is missing.
    $vmInstanceExists = Test-AzResourceExists -AzArgs @(
        "connectedvmware", "vm", "show"
        "--resource-group", $machineResourceGroup
        "--name", $machineName
        "--subscription", $machineSubscriptionId
    ) -Description "Reading virtualMachineInstance for machine '$machineName'"
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
# Step 2.0. Confirm with the operator before changing anything.
# ---------------------------------------------------------------------------

# Banner for the confirmation step.
Write-Host "`n=== Step 2.0: confirm before clearing the stale link ===" -ForegroundColor Cyan

# Repeat exactly which inventory item and which stale link are about to be acted on.
Write-Host "Inventory item     : moName='$($inventoryItem.moName)' name='$($inventoryItem.name)' moRefId='$($inventoryItem.moRefId)' kind='$($inventoryItem.kind)'"
Write-Host "Inventory item id  : $inventoryItemId"
Write-Host "Stale link         : $managedResourceId"

# Spell out the write operations so the operator knows what will happen.
if (-not $vmInstanceExists) { Write-Host "Will recreate placeholder machine '$machineName' in rg '$machineResourceGroup' (sub $machineSubscriptionId)." }
Write-Host "Will delete the Arc VM '$machineName' to clear the link (the vCenter VM is NOT touched)." -ForegroundColor Yellow

# The recreate in step 2.2 creates a virtualMachineInstance under the existing machine, and the
# service rejects that with a 400 unless the machine kind matches the vCenter kind exactly.
# Stop here with the way out rather than letting 'vm create' fail halfway through.
if ($machineExists -and -not $vmInstanceExists) {
    # We allow kind empty but if kind is set it must match the expected kind exactly.
    if (-not [string]::IsNullOrWhiteSpace($machineKind) -and -not $machineKind.Equals($expectedMachineKind, [StringComparison]::OrdinalIgnoreCase)) {
        # InvalidMachineKindInput: the name collides with a machine owned by another private cloud.
        Write-Host "`nSTOP: HCRP machine '$machineName' has kind '$machineKind' but this vCenter expects '$expectedMachineKind'." -ForegroundColor Red
        Write-Host "Step 2.2 would fail with 'InvalidMachineKindInput' (HTTP 400), and 'kind' cannot be changed." -ForegroundColor Red
        Write-Host "The stale link points at a machine owned by a different Arc private cloud. Ways out:" -ForegroundColor Yellow
        Write-Host "  1. If that machine is genuinely stale and NOT in use, delete it, then re-run this script" -ForegroundColor Yellow
        Write-Host "     so the placeholder is recreated with kind='$expectedMachineKind':" -ForegroundColor Yellow
        Write-Host "     az connectedmachine delete --ids $machineId" -ForegroundColor Yellow
        Write-Host "  2. If the machine is still in use by that private cloud, do NOT delete it - raise a support" -ForegroundColor Yellow
        Write-Host "     request to clear managedResourceId on the inventory item server-side." -ForegroundColor Yellow
        return
    } else {
        Write-Host "Placeholder resources for machine '$machineName' already exist and match the expected kind '$expectedMachineKind'. (Note: kind is allowed to be empty)" -ForegroundColor Green
    }
}

# When the HCRP machine still exists, deleting it is not the only option - linking is often preferred.
if ($machineExists) {
    Write-Host "`nNOTE: HCRP machine '$machineName' still exists. Instead of clearing this link you can link" -ForegroundColor Yellow
    Write-Host "the existing HCRP machine to this vCenter VM by enabling virtual hardware:" -ForegroundColor Yellow
    Write-Host "https://learn.microsoft.com/en-us/azure/azure-arc/vmware-vsphere/enable-virtual-hardware" -ForegroundColor Yellow
}

# Require an explicit 'yes' - anything else aborts without making changes.
$confirmation = Read-Host "`nProceed with clearing the stale link? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Host "Aborted - no resources were created or deleted." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Step 2.2 / 3.1. Recreate the missing placeholder resources.
# ---------------------------------------------------------------------------

# Skip this entirely when the chain is already whole - the delete can run as-is.
if (-not $vmInstanceExists) {
    # Banner for the recreate step.
    Write-Host "`n=== Step 2.2/3.1: recreating placeholder resources ===" -ForegroundColor Cyan

    # 'vm create' creates the HCRP machine with kind=VMware if it is missing, then the 'default' instance.
    $createArgs = @(
        "--resource-group", $machineResourceGroup   # must match the resource group in the stale ID
        "--name", $machineName                      # must match the machine name in the stale ID
        "--subscription", $machineSubscriptionId    # the machine may live in a different subscription
        "--inventory-item", $inventoryItemId        # binds the instance back to this inventory item
    )

    # Run the create - this is the CLI equivalent of the two REST PUTs in the TSG.
    az connectedvmware vm create @createArgs -o none

    # Without the placeholder the delete cannot clear the link - stop rather than delete blindly.
    if ($LASTEXITCODE -ne 0) { throw "Failed to recreate placeholder resources for machine '$machineName' in rg '$machineResourceGroup'." }

    # Confirm the chain is now whole so the delete has something to tear down.
    Write-Host "Placeholder machine and virtualMachineInstance created."
} else {
    Write-Host "Placeholder resources already exist for machine '$machineName' in rg '$machineResourceGroup'." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 2.3 / 3.2. Delete the Arc VM - this is what actually clears the stale link.
# ---------------------------------------------------------------------------

# Banner for the delete step.
Write-Host "`n=== Step 2.3/3.2: deleting the Arc VM (vCenter VM is NOT touched) ===" -ForegroundColor Cyan

# Require the operator to explicitly confirm the destructive operation immediately before it runs.
$deleteConfirmation = Read-Host "Type 'delete' to confirm deletion of Arc VM '$machineName'"
if ($deleteConfirmation -cne "delete") {
    Write-Host "Aborted - the Arc VM was not deleted." -ForegroundColor Yellow
    return
}

# Delete the Arc-side resources using the names from the stale link; --yes skips the confirmation prompt.
az connectedvmware vm delete `
    --resource-group $machineResourceGroup `
    --name $machineName `
    --subscription $machineSubscriptionId `
    --yes -o none

# A failed delete means the link was not cleared - stop instead of reporting a misleading result.
if ($LASTEXITCODE -ne 0) { throw "Failed to delete the Arc VM '$machineName' in rg '$machineResourceGroup'." }

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

# If the verification read fails we cannot claim success - stop with a clear message.
if ($LASTEXITCODE -ne 0) { throw "Delete completed, but verifying the inventory item for '$VmName' failed. Re-check the inventory item manually." }

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
