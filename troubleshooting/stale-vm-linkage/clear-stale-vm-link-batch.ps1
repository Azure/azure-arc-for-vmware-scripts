<#
.SYNOPSIS
    Clears stale inventory-links on many Arc-enabled VMware vSphere VMs in one non-interactive run.

.DESCRIPTION
    Batch version of clear-stale-vm-link.ps1. It follows the same process for every VM supplied
    (find the inventory item, work out which Azure resources are missing, recreate the missing
    placeholder resources, then delete the Arc VM so the delete clears the stale link) but it never
    prompts: the VM list is supplied up front and the destructive half of the process only runs when
    -Delete is passed.

    Without -Delete the script is read-only: it reports what it would do for every VM.
    With -Delete it recreates the placeholder resources and deletes the Arc VM for every VM that is
    safe to act on. A VM that cannot be handled safely is reported and skipped - the batch continues.

    Uses only 'az' CLI commands - no direct REST calls.
    Nothing in VMware vCenter is created, modified or deleted by this script.

.EXAMPLE
    # Report only - no changes are made.
    .\clear-stale-vm-link-batch.ps1 `
        -VCenterId "/subscriptions/0000..../resourceGroups/rg-vcenter/providers/Microsoft.ConnectedVMwarevSphere/vCenters/my-vcenter" `
        -VmNames "vm-a","vm-b","vm-c"

.EXAMPLE
    # Read the VM names from a file (one name per line) and clear the links.
    .\clear-stale-vm-link-batch.ps1 `
        -VCenterId "/subscriptions/0000..../resourceGroups/rg-vcenter/providers/Microsoft.ConnectedVMwarevSphere/vCenters/my-vcenter" `
        -VmNameFile .\vms.txt -Delete -ReportPath .\result.csv
#>

# Script parameters - the VM list is supplied up front so the run needs no operator input.
param(
    # Full ARM ID of the Microsoft.ConnectedVMwarevSphere/VCenters resource.
    [Parameter(Mandatory = $true)][string]$VCenterId,

    # VM names as they appear in vCenter (the inventory item "moName").
    [Parameter(Mandatory = $true, ParameterSetName = "Names")][string[]]$VmNames,

    # Text file holding one VM name per line. Blank lines and lines starting with '#' are ignored.
    [Parameter(Mandatory = $true, ParameterSetName = "File")][string]$VmNameFile,

    # Without this switch the run is read-only. With it, placeholders are recreated and the Arc VMs are deleted.
    [Parameter(Mandatory = $false)][switch]$Delete,

    # Optional path to write the per-VM result table as CSV.
    [Parameter(Mandatory = $false)][string]$ReportPath
)

# Stop the script on the first unhandled error so we never continue on bad data.
$ErrorActionPreference = "Stop"

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

# Build one row of the end-of-run summary table.
function New-VmResult {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][string]$MachineName = "",
        [Parameter(Mandatory = $false)][string]$StaleLink = "",
        [Parameter(Mandatory = $false)][string]$Detail = ""
    )

    # A flat object so the same data can be printed as a table and written as CSV.
    return [pscustomobject]@{
        VmName      = $VmName
        Status      = $Status
        MachineName = $MachineName
        StaleLink   = $StaleLink
        Detail      = $Detail
    }
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

# ---------------------------------------------------------------------------
# Step 0.1. Build the list of VM names to process.
# ---------------------------------------------------------------------------

# Banner so the log is easy to read.
Write-Host "=== Step 0: preparing the batch ===" -ForegroundColor Cyan

# When a file was supplied, read it instead of the inline list.
if ($PSCmdlet.ParameterSetName -eq "File") {
    # Fail early with a clear message rather than an empty batch.
    if (-not (Test-Path -LiteralPath $VmNameFile)) { throw "VM name file not found: $VmNameFile" }

    # One name per line; blank lines and '#' comments are ignored so the file can be annotated.
    $VmNames = @(Get-Content -LiteralPath $VmNameFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })
}

# Trim and drop empties, then de-duplicate so a repeated name is not processed twice.
$vmNameList = @($VmNames | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

# Nothing to do means the input was empty - stop rather than report a misleading success.
if ($vmNameList.Count -eq 0) { throw "No VM names were supplied." }

# Show the size of the batch and the mode it will run in.
Write-Host "VMs to process     : $($vmNameList.Count)"
Write-Host "Mode               : $(if ($Delete) { 'DELETE - placeholders will be recreated and Arc VMs deleted' } else { 'REPORT ONLY - no resources will be created or deleted (pass -Delete to act)' })" -ForegroundColor $(if ($Delete) { "Yellow" } else { "Green" })

# ---------------------------------------------------------------------------
# Step 0.2. Confirm the Azure CLI is available and point it at the vCenter's subscription.
# ---------------------------------------------------------------------------

# Fail early with a clear message if the az CLI is not installed or not on PATH.
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI ('az') was not found on PATH." }

# Set the active subscription so the inventory/vCenter lookups target the right place.
az account set --subscription $VCenterSubscriptionId | Out-Null

# A failure here means the subscription is wrong or the session is not logged in - stop now.
if ($LASTEXITCODE -ne 0) { throw "Failed to set the active subscription to '$VCenterSubscriptionId'. Check 'az login' and the subscription id." }

# Confirm to the operator which subscription is now active.
Write-Host "Using subscription : $VCenterSubscriptionId"

# ---------------------------------------------------------------------------
# Step 0.3. Read the vCenter once - custom location, kind and resource bridge health.
# ---------------------------------------------------------------------------

# Every step below depends on the Arc resource bridge, so its status is checked instead of asking the operator.
$vCenterJson = az connectedvmware vcenter show `
    --name $VCenterName `
    --resource-group $VCenterResourceGroup `
    --subscription $VCenterSubscriptionId `
    --query "{customLocation:extendedLocation.name, kind:kind, connectionStatus:connectionStatus}" -o json

# Distinguish "could not read the vCenter" from "the vCenter has no custom location".
if ($LASTEXITCODE -ne 0) { throw "Failed to read vCenter '$VCenterName' in rg '$VCenterResourceGroup'." }

# Convert the small projection into an object.
$vCenterInfo = $vCenterJson | ConvertFrom-Json

# The custom location that 'vm create' will stamp on the recreated resources.
$customLocationId = $vCenterInfo.customLocation

# The kind the HCRP machine must carry - 'VMware' normally, 'AVS' for an AVS-backed vCenter.
$expectedMachineKind = if ([string]::IsNullOrWhiteSpace($vCenterInfo.kind)) { "VMware" } else { $vCenterInfo.kind }

# Without a custom location the resource bridge is broken and nothing below will work.
if ([string]::IsNullOrWhiteSpace($customLocationId)) { throw "Could not read extendedLocation.name from vCenter '$VCenterName'. The resource bridge may be broken." }

# A vCenter that is not connected means the bridge is down - the recreate/delete steps would fail for every VM.
if (-not [string]::IsNullOrWhiteSpace($vCenterInfo.connectionStatus) -and $vCenterInfo.connectionStatus -ne "Connected") {
    throw "vCenter '$VCenterName' has connectionStatus '$($vCenterInfo.connectionStatus)'. Bring the Azure Arc resource bridge online, then re-run this script."
}

# Show what the whole batch will run against.
Write-Host "Custom location    : $customLocationId"
Write-Host "Expected kind      : $expectedMachineKind or empty"
Write-Host "Connection status  : $(if ([string]::IsNullOrWhiteSpace($vCenterInfo.connectionStatus)) { '(not reported)' } else { $vCenterInfo.connectionStatus })"

# ---------------------------------------------------------------------------
# Step 1. Read the whole inventory once and index it by VM name.
# ---------------------------------------------------------------------------

# Banner for the inventory read.
Write-Host "`n=== Step 1: reading the vCenter inventory ===" -ForegroundColor Cyan

# One list call serves the whole batch - far cheaper than a filtered call per VM.
$inventoryJson = az connectedvmware vcenter inventory-item list `
    --resource-group $VCenterResourceGroup `
    --vcenter $VCenterName `
    --subscription $VCenterSubscriptionId `
    --query "[?kind=='VirtualMachine']" -o json

# A failed list tells us nothing about the inventory - do not treat it as "no items found".
if ($LASTEXITCODE -ne 0) { throw "Failed to list inventory items for vCenter '$VCenterName' in rg '$VCenterResourceGroup'." }

# Convert the JSON array returned by the CLI into PowerShell objects.
$allInventoryItems = @($inventoryJson | ConvertFrom-Json)

# Group by moName so each VM in the batch is a dictionary lookup rather than another API call.
$inventoryByName = @{}
foreach ($item in $allInventoryItems) {
    # Inventory items with no moName cannot be matched to a supplied VM name.
    if ([string]::IsNullOrWhiteSpace($item.moName)) { continue }

    # Collect every item sharing a name - duplicates are reported per VM rather than guessed at.
    if (-not $inventoryByName.ContainsKey($item.moName)) { $inventoryByName[$item.moName] = @() }
    $inventoryByName[$item.moName] += $item
}

# Show how much inventory the batch is matching against.
Write-Host "Inventory items    : $($allInventoryItems.Count) virtual machines"

# ---------------------------------------------------------------------------
# Step 2. Process each VM with the same logic as the single-VM script.
# ---------------------------------------------------------------------------

# Collects one row per VM for the summary table.
$results = @()

# Counter used only for the progress line.
$vmIndex = 0

foreach ($vmName in $vmNameList) {
    # Track position in the batch so a long run is easy to follow.
    $vmIndex++

    # Banner per VM.
    Write-Host "`n=== [$vmIndex/$($vmNameList.Count)] $vmName ===" -ForegroundColor Cyan

    try {
        # --- Step 2.1. Find the inventory item for this VM and read its managedResourceId. ---

        # Look the name up in the index built from the single inventory read.
        $matchingItems = @($inventoryByName[$vmName])

        # If nothing came back, the VM name does not match any inventory item - skip it.
        if ($matchingItems.Count -eq 0) {
            Write-Host "No inventory item found with moName '$vmName'." -ForegroundColor Yellow
            $results += New-VmResult -VmName $vmName -Status "NotFound" -Detail "No inventory item with this moName in vCenter '$VCenterName'."
            continue
        }

        # More than one match cannot be resolved without operator input, and this script never prompts - skip it.
        if ($matchingItems.Count -gt 1) {
            $moRefIds = ($matchingItems | ForEach-Object { $_.moRefId }) -join ", "
            Write-Host "Found $($matchingItems.Count) inventory items named '$vmName' (moRefIds: $moRefIds)." -ForegroundColor Yellow
            Write-Host "Skipped - use clear-stale-vm-link.ps1 to pick the right one interactively." -ForegroundColor Yellow
            $results += New-VmResult -VmName $vmName -Status "Ambiguous" -Detail "$($matchingItems.Count) inventory items share this name (moRefIds: $moRefIds). Use clear-stale-vm-link.ps1."
            continue
        }

        # Take the single matching inventory item.
        $inventoryItem = $matchingItems[0]

        # The full ARM ID of the inventory item - passed to 'vm create' as --inventory-item.
        $inventoryItemId = $inventoryItem.id

        # The pointer we are trying to clear - the ARM ID the inventory item is linked to.
        $managedResourceId = $inventoryItem.managedResourceId

        # Show the operator what was found.
        Write-Host "Inventory item id  : $inventoryItemId"
        Write-Host "managedResourceId  : '$managedResourceId'"

        # --- Step 2.2. Decide whether there is actually a stale link to clear. ---

        # An empty managedResourceId means the VM is simply not Arc-enabled - there is nothing to fix.
        if ([string]::IsNullOrWhiteSpace($managedResourceId)) {
            Write-Host "managedResourceId is already empty - no stale link. Nothing to do." -ForegroundColor Green
            $results += New-VmResult -VmName $vmName -Status "NoStaleLink" -Detail "managedResourceId is already empty."
            continue
        }

        # Pull the subscription id out of the stale ID - the placeholder must be recreated here.
        $machineSubscriptionId = [regex]::Match($managedResourceId, '(?i)/subscriptions/([^/]+)').Groups[1].Value

        # Pull the resource group out of the stale ID - the placeholder must be recreated here.
        $machineResourceGroup = [regex]::Match($managedResourceId, '(?i)/resourceGroups/([^/]+)').Groups[1].Value

        # Pull the HCRP machine name out of the stale ID - the placeholder must reuse this exact name.
        $machineName = [regex]::Match($managedResourceId, '(?i)/machines/([^/]+)').Groups[1].Value

        # If any of the three could not be parsed, the ID is not in a shape this script understands.
        if (-not $machineSubscriptionId -or -not $machineResourceGroup -or -not $machineName) {
            throw "Could not parse subscription/resource group/machine name from managedResourceId: $managedResourceId"
        }

        # Rebuild the canonical machine ARM ID from the parsed pieces so later calls are consistent.
        $machineId = "/subscriptions/$machineSubscriptionId/resourceGroups/$machineResourceGroup/providers/Microsoft.HybridCompute/machines/$machineName"

        # Show the names that must be matched exactly - a mismatch here is the usual reason the fix fails.
        Write-Host "Linked machine     : $machineName (sub $machineSubscriptionId, rg $machineResourceGroup)"

        # --- Step 2.3. Check whether the HCRP (Arc) machine and its VM instance still exist. ---

        # Try to read the Arc machine; a not-found means it is gone, any other error stops the script.
        $machineExists = Test-AzResourceExists -AzArgs @("connectedmachine", "show", "--ids", $machineId) `
            -Description "Reading HCRP machine '$machineName'"

        # The 'kind' on an existing machine decides whether a VM instance can be created under it.
        $machineKind = $null
        if ($machineExists) {
            $machineKind = az connectedmachine show --ids $machineId --query "kind" -o tsv

            # Without the kind we cannot tell whether the recreate below would be rejected.
            if ($LASTEXITCODE -ne 0) { throw "Failed to read the 'kind' property of HCRP machine '$machineName'." }
        }

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

        # Report the state both branches of the TSG depend on.
        Write-Host "HCRP machine exists: $machineExists$(if ($machineExists) { " (kind '$machineKind')" })"
        Write-Host "VM instance exists : $vmInstanceExists"

        # --- Step 2.4. Refuse to act when the recreate would be rejected by the service. ---

        # The recreate creates a virtualMachineInstance under the existing machine, and the service
        # rejects that with a 400 unless the machine kind matches the vCenter kind exactly.
        # Kind is allowed to be empty, but a set kind must match.
        $kindMismatch = $machineExists -and -not $vmInstanceExists -and
            -not [string]::IsNullOrWhiteSpace($machineKind) -and
            -not $machineKind.Equals($expectedMachineKind, [StringComparison]::OrdinalIgnoreCase)

        if ($kindMismatch) {
            # InvalidMachineKindInput: the name collides with a machine owned by another private cloud.
            Write-Host "STOP: HCRP machine '$machineName' has kind '$machineKind' but this vCenter expects '$expectedMachineKind'." -ForegroundColor Red
            Write-Host "The recreate would fail with 'InvalidMachineKindInput' (HTTP 400), and 'kind' cannot be changed." -ForegroundColor Red
            Write-Host "If that machine is genuinely stale and NOT in use, delete it and re-run:" -ForegroundColor Yellow
            Write-Host "  az connectedmachine delete --ids $machineId" -ForegroundColor Yellow
            Write-Host "If it is still in use by that private cloud, do NOT delete it - raise a support request instead." -ForegroundColor Yellow

            $results += New-VmResult -VmName $vmName -Status "Blocked" -MachineName $machineName -StaleLink $managedResourceId `
                -Detail "HCRP machine kind '$machineKind' does not match the expected kind '$expectedMachineKind'. The link points at a machine owned by another Arc private cloud."
            continue
        }

        # --- Step 2.5. In report-only mode, record the planned actions and move on. ---

        # The plan is the same set of writes step 2.6 would perform.
        $plannedActions = @()
        if (-not $vmInstanceExists) { $plannedActions += "recreate placeholder machine '$machineName' in rg '$machineResourceGroup' (sub $machineSubscriptionId)" }
        $plannedActions += "delete Arc VM '$machineName' to clear the link (the vCenter VM is NOT touched)"

        if (-not $Delete) {
            # Spell out what would happen so the report is actionable on its own.
            Write-Host "Would: $($plannedActions -join '; ')." -ForegroundColor Yellow

            # An existing HCRP machine can often be linked instead of cleared - flag that while it is still reversible.
            if ($machineExists) {
                Write-Host "NOTE: the HCRP machine still exists. Instead of clearing this link you can link it to the" -ForegroundColor Yellow
                Write-Host "vCenter VM by enabling virtual hardware: https://learn.microsoft.com/en-us/azure/azure-arc/vmware-vsphere/enable-virtual-hardware" -ForegroundColor Yellow
            }

            $results += New-VmResult -VmName $vmName -Status "WouldClear" -MachineName $machineName -StaleLink $managedResourceId `
                -Detail "$($plannedActions -join '; '). HCRP machine exists: $machineExists."
            continue
        }

        # --- Step 2.6. Recreate the missing placeholder resources. ---

        # Skip this entirely when the chain is already whole - the delete can run as-is.
        if (-not $vmInstanceExists) {
            # 'vm create' creates the HCRP machine with the vCenter's kind if it is missing, then the 'default' instance.
            $createArgs = @(
                "--resource-group", $machineResourceGroup   # must match the resource group in the stale ID
                "--name", $machineName                      # must match the machine name in the stale ID
                "--subscription", $machineSubscriptionId    # the machine may live in a different subscription
                "--inventory-item", $inventoryItemId        # binds the instance back to this inventory item
            )

            # Run the create - this is the CLI equivalent of the two REST PUTs in the TSG.
            az connectedvmware vm create @createArgs -o none

            # Without the placeholder the delete cannot clear the link - skip this VM rather than delete blindly.
            if ($LASTEXITCODE -ne 0) { throw "Failed to recreate placeholder resources for machine '$machineName' in rg '$machineResourceGroup'." }

            # Confirm the chain is now whole so the delete has something to tear down.
            Write-Host "Placeholder machine and virtualMachineInstance created."
        }

        # --- Step 2.7. Delete the Arc VM - this is what actually clears the stale link. ---

        # Delete the Arc-side resources using the names from the stale link; --yes skips the CLI confirmation prompt.
        az connectedvmware vm delete `
            --resource-group $machineResourceGroup `
            --name $machineName `
            --subscription $machineSubscriptionId `
            --yes -o none

        # A failed delete means the link was not cleared - report it instead of a misleading result.
        if ($LASTEXITCODE -ne 0) { throw "Failed to delete the Arc VM '$machineName' in rg '$machineResourceGroup'." }

        # Confirm the delete call returned.
        Write-Host "Delete completed."

        # --- Step 2.8. Verify that managedResourceId is now empty. ---

        # Re-read just this inventory item - the cached list from step 1 is now out of date for this VM.
        $verifyJson = az connectedvmware vcenter inventory-item list `
            --resource-group $VCenterResourceGroup `
            --vcenter $VCenterName `
            --subscription $VCenterSubscriptionId `
            --query "[?moName=='$vmName'].managedResourceId" -o json

        # If the verification read fails we cannot claim success - report it as unverified.
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Delete completed, but the verification read failed. Re-check this inventory item manually." -ForegroundColor Yellow
            $results += New-VmResult -VmName $vmName -Status "Unverified" -MachineName $machineName -StaleLink $managedResourceId `
                -Detail "Delete completed, but re-reading the inventory item failed."
            continue
        }

        # Convert the result (an array with at most one string) into PowerShell objects.
        $verifyValue = @($verifyJson | ConvertFrom-Json)[0]

        # An empty value means the stale link is gone and the VM can be Arc-enabled again.
        if ([string]::IsNullOrWhiteSpace($verifyValue)) {
            Write-Host "SUCCESS: managedResourceId is now empty - the stale link has been cleared." -ForegroundColor Green
            $results += New-VmResult -VmName $vmName -Status "Cleared" -MachineName $machineName -StaleLink $managedResourceId `
                -Detail "managedResourceId is now empty."
        } else {
            # Report failure and point at the most common cause (a name mismatch).
            Write-Host "WARNING: managedResourceId is still '$verifyValue'." -ForegroundColor Red
            $results += New-VmResult -VmName $vmName -Status "StillLinked" -MachineName $machineName -StaleLink $managedResourceId `
                -Detail "managedResourceId is still '$verifyValue'. Check that the recreated machine used the exact subscription/resource group/name from the stale ID."
        }
    } catch {
        # One bad VM must not end the batch - record the error and carry on with the next name.
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results += New-VmResult -VmName $vmName -Status "Error" -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Step 3. Summarise the batch.
# ---------------------------------------------------------------------------

# Banner for the summary.
Write-Host "`n=== Summary ===" -ForegroundColor Cyan

# Per-VM outcome, in the order the names were supplied.
$results | Format-Table VmName, Status, MachineName, Detail -AutoSize -Wrap

# Counts per status so a large batch can be judged at a glance.
Write-Host "Totals:"
$results | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }

# Write the same rows to CSV when a path was supplied.
if ($ReportPath) {
    $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nReport written to: $ReportPath"
}

# Remind the operator that a report-only run changed nothing, and how to act on it.
if (-not $Delete) {
    Write-Host "`nREPORT ONLY - no resources were created or deleted. Re-run with -Delete to clear the links above." -ForegroundColor Yellow
}

# A non-zero exit code lets a caller detect that some VMs need attention.
if (@($results | Where-Object { $_.Status -in @("Error", "StillLinked", "Unverified") }).Count -gt 0) { exit 1 }
