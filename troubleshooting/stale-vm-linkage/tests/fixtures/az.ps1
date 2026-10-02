$ErrorActionPreference = 'Stop'
if (-not $env:STALE_VM_LINK_TEST_CONFIG) { throw 'This fake az requires a test configuration.' }
$config = Get-Content -LiteralPath $env:STALE_VM_LINK_TEST_CONFIG -Raw | ConvertFrom-Json

$queryIndex = [Array]::IndexOf($args, '--query')
$query = if ($queryIndex -ge 0) { $args[$queryIndex + 1] } else { '' }
$nameIndex = [Array]::IndexOf($args, '--name')
$name = if ($nameIndex -ge 0) { $args[$nameIndex + 1] } else { 'vm-a' }
if ($args[0] -eq 'account' -and $args[1] -eq 'set') {
    $operation = 'account'
} elseif ($args[0] -eq 'connectedmachine' -and $args[1] -eq 'show') {
    $operation = if ($query) { 'kind' } else { 'machine' }
    $name = ($args[[Array]::IndexOf($args, '--ids') + 1] -split '/')[-1]
} elseif ($args[0] -eq 'connectedvmware' -and $args[1] -eq 'vcenter' -and $args[2] -eq 'inventory-item') {
    $operation = if ($query.EndsWith('.managedResourceId')) { 'verify' } else { 'inventory' }
    if ($query -match "moName=='([^']+)'") { $name = $Matches[1] }
} elseif ($args[0] -eq 'connectedvmware' -and $args[1] -eq 'vcenter' -and $args[2] -eq 'show') {
    $operation = 'vcenter'
} elseif ($args[0] -eq 'connectedvmware' -and $args[1] -eq 'vm' -and $args[2] -in @('show', 'create', 'delete')) {
    $operation = $args[2]
} else {
    throw "Unexpected fake az invocation: $args"
}

$call = @{ Operation = $operation; Name = $name; Arguments = @($args) } | ConvertTo-Json -Compress
Add-Content -LiteralPath $config.CallsPath -Value $call
if ($config.EmitWarning) {
    # Console stderr crosses a real process boundary; Write-Error would test a different failure.
    [Console]::Error.WriteLine('SyntaxWarning: "\ " is an invalid escape sequence.')
    [Console]::Error.WriteLine('  simulated connectedvmware SDK warning')
}
if ($operation -eq $config.FailOperation -and (-not $config.FailVm -or $config.FailVm -eq $name)) {
    if (-not $config.SilentFailure) { [Console]::Error.WriteLine($config.ErrorText) }
    exit 7
}
if (($operation -eq 'machine' -and -not $config.MachineExists) -or
    ($operation -eq 'show' -and -not $config.InstanceExists)) {
    [Console]::Error.WriteLine('(ResourceNotFound) simulated missing resource')
    exit 3
}
if ($operation -eq $config.MalformedOperation -and (-not $config.MalformedVm -or $config.MalformedVm -eq $name)) {
    [Console]::Out.WriteLine('{not-json')
    exit 0
}

switch ($operation) {
    'inventory' {
        $items = @(
            foreach ($vm in $config.VmNames) {
                @{
                    id = "/subscriptions/s/resourceGroups/r/providers/Microsoft.ConnectedVMwarevSphere/vCenters/v/inventoryItems/$vm"
                    moName = $vm
                    name = $vm
                    moRefId = "moref-$vm"
                    kind = 'VirtualMachine'
                    managedResourceId = if ($config.NoStaleLink) { '' } elseif ($config.ManagedResourceId) {
                        $config.ManagedResourceId
                    } else {
                        "/subscriptions/s/resourceGroups/r/providers/Microsoft.HybridCompute/machines/$vm"
                    }
                }
            }
        )
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $items -Compress))
    }
    'vcenter' {
        [Console]::Out.WriteLine((@{
            customLocation = $config.CustomLocation
            kind = $config.VCenterKind
            connectionStatus = $config.ConnectionStatus
            location = 'eastus'
        } | ConvertTo-Json -Compress))
    }
    'kind' { [Console]::Out.WriteLine([string]$config.MachineKind) }
    'verify' {
        [Console]::Out.WriteLine($(if ($config.StillLinked) { '["still-linked"]' } else { '[""]' }))
    }
}
exit 0
