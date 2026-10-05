#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Offline regression tests for CLI setup and both stale-link scripts on Windows.
.DESCRIPTION
    Goal: allow harmless native warnings without weakening the scripts' safety gates.
    Successful flows must target the linked Azure resources, recreate only what is
    missing, delete in order, and verify before claiming success. Exception flows
    must stop unsafe follow-up actions and expose the failure, while a batch must
    continue processing independent VMs and preserve each outcome in its CSV report.
    These tests validate script decisions and CLI arguments, not Azure service behavior.
.EXAMPLE
    Invoke-Pester .\troubleshooting\stale-vm-linkage\tests -Output Detailed
.NOTES
    Run with Pester 5 in Windows PowerShell 5.1 and PowerShell 7.
    az is bound to a native fixture in an isolated runspace. No Azure CLI or login
    is needed. Ordinary function mocks do not reproduce native stderr handling.
#>

BeforeDiscovery {
    $runs = @(
        foreach ($kind in @('single', 'batch')) {
            $nativeModes = @($false)
            if ($PSVersionTable.PSVersion.Major -ge 7) { $nativeModes += $true }
            foreach ($native in $nativeModes) {
                @{ Kind = $kind; NativeErrors = $native }
            }
        }
    )
    $failures = @(
        foreach ($operation in @('account', 'inventory', 'vcenter', 'kind', 'machine', 'show', 'create', 'delete', 'verify')) {
            foreach ($silent in @($false, $true)) {
                @{ Operation = $operation; Silent = $silent }
            }
        }
    )
    $setupRuns = @($runs | Where-Object Kind -eq 'single' | ForEach-Object {
        @{ Kind = 'setup'; NativeErrors = $_.NativeErrors }
    })
}

BeforeAll {
    $testsRoot = $PSScriptRoot
    function Invoke-StaleLinkScenario {
        param(
            [string]$Kind,
            [bool]$NativeErrors,
            [hashtable]$Overrides = @{},
            [switch]$ReadOnly,
            [string]$Decision = 'proceed',
            [string]$VCenterId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.ConnectedVMwarevSphere/vCenters/v'
        )

        $directory = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $configPath = Join-Path $directory.FullName 'config.json'
        $callsPath = Join-Path $directory.FullName 'calls.jsonl'
        $reportPath = Join-Path $directory.FullName 'report.csv'
        $config = @{
            CallsPath = $callsPath; EmitWarning = $true
            MachineExists = $true; InstanceExists = $false
            VmNames = @('vm-a'); ErrorText = 'AuthorizationFailed: simulated failure'; FailExitCode = 7
            MachineKind = 'VMware'; VCenterKind = 'VMware'; ConnectionStatus = 'Connected'
            CustomLocation = '/subscriptions/s/resourceGroups/r/providers/Microsoft.ExtendedLocation/customLocations/c'
            InstalledExtensions = @('connectedvmware', 'connectedmachine', 'scvmm')
            UnavailableExtensions = @(); RepairIneffective = $false
        }
        foreach ($key in $Overrides.Keys) { $config[$key] = $Overrides[$key] }
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

        $fileName = if ($Kind -eq 'setup') { 'setup-azure-cli.ps1' }
                    elseif ($Kind -eq 'batch') { 'clear-stale-vm-link-batch.ps1' }
                    else { 'clear-stale-vm-link.ps1' }
        $file = Join-Path (Split-Path $testsRoot -Parent) $fileName
        $fixture = Join-Path $testsRoot 'fixtures\az.cmd'
        $parameters = @{ VCenterId = $VCenterId }
        if ($Kind -eq 'setup') {
            $parameters = @{}
        } elseif ($Kind -eq 'batch') {
            $parameters.VmNames = $config.VmNames
            $parameters.Delete = -not $ReadOnly
            $parameters.ReportPath = $reportPath
        } else {
            $parameters.VmName = 'vm-a'
            $parameters.CheckOnly = [bool]$ReadOnly
        }

        $previousConfig = $env:STALE_VM_LINK_TEST_CONFIG
        $ps = [powershell]::Create()
        try {
            $env:STALE_VM_LINK_TEST_CONFIG = $configPath
            $null = $ps.AddScript({
                param($File, $Parameters, $Fixture, $NativeErrors, $Decision)
                $ErrorActionPreference = 'Stop'
                $PSNativeCommandUseErrorActionPreference = $NativeErrors
                $global:LASTEXITCODE = 99
                # An alias to a .cmd still invokes a native process, but cannot fall through to real az.
                Set-Alias -Name az -Value $Fixture -Scope Global
                if ((Get-Command az).ResolvedCommand.Path -ne $Fixture) { throw 'Fake az did not resolve.' }
                function Read-Host {
                    param([string]$Prompt)
                    if ($Decision -eq 'abort') { return 'no' }
                    if ($Prompt -like "*Type 'I confirm'*") { return 'I confirm' }
                    if ($Prompt -like '*Proceed with clearing*' -and $Decision -eq 'decline-change') { return 'no' }
                    if ($Prompt -like "*Type 'delete'*") {
                        if ($Decision -eq 'keep') { return 'keep' }
                        return 'delete'
                    }
                    return 'yes'
                }
                $failure = $null
                try { & $File @Parameters | Out-Null } catch { $failure = $_ }
                [pscustomobject]@{
                    Failure = $failure
                    ExitCode = $LASTEXITCODE
                    Preference = [string]$ErrorActionPreference
                }
            }).AddArgument($file).AddArgument($parameters).AddArgument($fixture).AddArgument($NativeErrors).AddArgument($Decision)
            $output = @($ps.Invoke())
            if ($ps.InvocationStateInfo.State -ne 'Completed' -or $output.Count -ne 1) {
                throw "Test runspace failed: $($ps.InvocationStateInfo.Reason)"
            }
            [pscustomobject]@{
                Failure = $output[0].Failure
                ExitCode = $output[0].ExitCode
                Preference = $output[0].Preference
                Diagnostics = ($ps.Streams.Error | Out-String)
                Messages = ($ps.Streams.Information | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
                Calls = @(if (Test-Path $callsPath) { Get-Content $callsPath | ForEach-Object { $_ | ConvertFrom-Json } })
                Rows = @(if (Test-Path $reportPath) { Import-Csv $reportPath })
            }
        } finally {
            $ps.Dispose()
            $env:STALE_VM_LINK_TEST_CONFIG = $previousConfig
        }
    }
}

Describe '<Kind> script (native error preference: <NativeErrors>)' -ForEach $runs -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $runParameters = @{ Kind = $Kind; NativeErrors = $NativeErrors }
    }

    # Regression goal: stderr is diagnostic, not proof of failure. Check visible warnings,
    # clean JSON/TSV consumption, final verification, and isolation of the Continue preference.
    It 'keeps warning-only stderr visible and JSON/TSV usable through create, delete, and verification' {
        $result = Invoke-StaleLinkScenario @runParameters
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.Preference | Should -Be 'Stop'
        $result.Diagnostics | Should -Match 'SyntaxWarning'
        $result.Diagnostics | Should -Match 'simulated connectedvmware SDK warning'
        @($result.Calls | Where-Object { $_.Operation -in @('extension-add', 'extension-update') }).Count | Should -Be 0
        $result.Messages | Should -Match 'SUCCESS: managedResourceId is now empty'
        @($result.Calls.Operation) | Should -Contain 'kind'
        @($result.Calls.Operation) | Should -Contain 'create'
        @($result.Calls.Operation) | Should -Contain 'delete'
        $result.Calls[-1].Operation | Should -Be 'verify'
        if ($Kind -eq 'batch') { $result.Rows[0].Status | Should -Be 'Cleared' }
    }

    It 'also succeeds without stderr warnings' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ EmitWarning = $false }
        $result.Failure | Should -BeNullOrEmpty
        $result.Diagnostics | Should -Not -Match 'SyntaxWarning'
        $result.Messages | Should -Match 'SUCCESS:'
    }

    # Separation goal: VM troubleshooting must never perform local setup, even in write
    # mode. The operator runs setup-azure-cli.ps1 separately when tooling needs attention.
    It 'never installs or upgrades tooling (read-only: <ReadOnly>)' -ForEach @(
        @{ ReadOnly = $false }
        @{ ReadOnly = $true }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -ReadOnly:$ReadOnly
        $result.Failure | Should -BeNullOrEmpty
        $result.Calls[0].Operation | Should -Be 'account'
        @($result.Calls | Where-Object { $_.Operation -eq 'upgrade' -or $_.Operation -like 'extension-*' }).Count | Should -Be 0
        if ($ReadOnly) {
            @($result.Calls.Operation) | Should -Not -Contain 'create'
            @($result.Calls.Operation) | Should -Not -Contain 'delete'
        } else {
            $result.ExitCode | Should -Be 0
            $result.Messages | Should -Match 'SUCCESS:'
        }
    }

    # Lifecycle goal: validate the entire command sequence, not just a success message.
    # Exact argument checks ensure recreation/deletion use the stale ID and inventory item,
    # and that an existing instance is never unnecessarily recreated.
    It 'completes the ordered successful flow for <Scenario>' -ForEach @(
        @{ Scenario = 'a missing machine'; MachineExists = $false; InstanceExists = $false }
        @{ Scenario = 'a missing VM instance'; MachineExists = $true; InstanceExists = $false }
        @{ Scenario = 'an existing VM instance'; MachineExists = $true; InstanceExists = $true }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            MachineExists = $MachineExists; InstanceExists = $InstanceExists; EmitWarning = $false
        }
        $expected = if ($Kind -eq 'batch') { @('account', 'vcenter', 'inventory', 'machine') }
                    else { @('account', 'inventory', 'machine') }
        if ($MachineExists) { $expected += 'kind' }
        if ($Kind -eq 'single') { $expected += 'vcenter' }
        if ($MachineExists) { $expected += 'show' }
        if (-not $InstanceExists) { $expected += 'create' }
        $expected += @('delete', 'verify')
        ($result.Calls.Operation -join ',') | Should -Be ($expected -join ',')
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.Messages | Should -Match 'SUCCESS: managedResourceId is now empty'

        foreach ($call in @($result.Calls | Where-Object { $_.Operation -in @('create', 'delete') })) {
            $expectedArgs = @('connectedvmware', 'vm', $call.Operation,
                '--resource-group', 'r', '--name', 'vm-a', '--subscription', 's')
            if ($call.Operation -eq 'create') {
                $expectedArgs += @('--inventory-item', '/subscriptions/s/resourceGroups/r/providers/Microsoft.ConnectedVMwarevSphere/vCenters/v/inventoryItems/vm-a')
            } else { $expectedArgs += '--yes' }
            $expectedArgs += @('-o', 'none')
            ($call.Arguments -join '|') | Should -Be ($expectedArgs -join '|')
        }
        if ($Kind -eq 'batch') {
            $result.Rows.Count | Should -Be 1
            $result.Rows[0].VmName | Should -Be 'vm-a'
            $result.Rows[0].MachineName | Should -Be 'vm-a'
            $result.Rows[0].StaleLink | Should -Be '/subscriptions/s/resourceGroups/r/providers/Microsoft.HybridCompute/machines/vm-a'
            $result.Rows[0].Status | Should -Be 'Cleared'
        }
    }

    # The linked machine deliberately lives outside the vCenter subscription/resource group;
    # both reads and writes must use that stale ID, not the active vCenter subscription.
    It 'uses the linked machine subscription and resource group (machine exists: <MachineExists>)' -ForEach @(
        @{ MachineExists = $true }
        @{ MachineExists = $false }
    ) {
        $machineId = '/subscriptions/machine-sub/resourceGroups/machine-rg/providers/Microsoft.HybridCompute/machines/vm-a'
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            MachineExists = $MachineExists
            ManagedResourceId = $machineId
        }
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.Messages | Should -Match 'SUCCESS: managedResourceId is now empty'
        $machineRead = @($result.Calls | Where-Object Operation -eq 'machine')
        $machineRead.Count | Should -Be 1
        ($machineRead[0].Arguments -join '|') | Should -Be "connectedmachine|show|--ids|$machineId|-o|none"
        $kindReads = @($result.Calls | Where-Object Operation -eq 'kind')
        if ($MachineExists) {
            $kindReads.Count | Should -Be 1
            ($kindReads[0].Arguments -join '|') | Should -Be "connectedmachine|show|--ids|$machineId|--query|kind|-o|tsv"
        } else { $kindReads.Count | Should -Be 0 }
        $writes = @($result.Calls | Where-Object { $_.Operation -in @('create', 'delete') })
        ($writes.Operation -join ',') | Should -Be 'create,delete'
        foreach ($call in $writes) {
            $arguments = @($call.Arguments)
            $arguments[[Array]::IndexOf($arguments, '--subscription') + 1] | Should -Be 'machine-sub'
            $arguments[[Array]::IndexOf($arguments, '--resource-group') + 1] | Should -Be 'machine-rg'
        }
        if ($Kind -eq 'batch') {
            $result.Rows[0].Status | Should -Be 'Cleared'
            $result.Rows[0].StaleLink | Should -Be $machineId
        }
    }

    # Exit code 2 is a CLI failure, not evidence of a missing Azure resource. Even with
    # warning noise, an unrecognized read command must stop this VM before create/delete.
    It 'does not treat CLI exit code 2 from <Operation> as a missing resource' -ForEach @(
        @{ Operation = 'machine'; Command = 'connectedmachine' }
        @{ Operation = 'show'; Command = 'connectedvmware' }
    ) {
        $errorText = "ERROR: '$Command' is misspelled or not recognized by the system."
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            FailOperation = $Operation; FailExitCode = 2; ErrorText = $errorText
        }
        $result.Calls[-1].Operation | Should -Be $Operation
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        $result.Messages | Should -Not -Match 'SUCCESS:'
        if ($Kind -eq 'batch') {
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            $result.Rows[0].Status | Should -Be 'Error'
            $result.Rows[0].Detail | Should -Match 'exit code 2'
            $result.Rows[0].Detail | Should -Match ([regex]::Escape($errorText))
        } else {
            $result.ExitCode | Should -Be 2
            $result.Failure.Exception.Message | Should -Match 'exit code 2'
            $result.Failure.Exception.Message | Should -Match ([regex]::Escape($errorText))
        }
    }

    # Compatibility goal: accepted kind values must still reach create/delete/verify.
    # Empty kinds, case differences, and AVS must not be mistaken for a foreign machine.
    It 'allows compatible kinds: <Scenario>' -ForEach @(
        @{ Scenario = 'empty machine kind'; MachineKind = ''; VCenterKind = 'VMware' }
        @{ Scenario = 'case-insensitive match'; MachineKind = 'vmware'; VCenterKind = 'VMware' }
        @{ Scenario = 'AVS match'; MachineKind = 'AVS'; VCenterKind = 'AVS' }
        @{ Scenario = 'default vCenter kind'; MachineKind = 'VMware'; VCenterKind = '' }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            MachineKind = $MachineKind; VCenterKind = $VCenterKind
        }
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        ($result.Calls[-3..-1].Operation -join ',') | Should -Be 'create,delete,verify'
        $result.Messages | Should -Match 'SUCCESS:'
        if ($Kind -eq 'batch') { $result.Rows[0].Status | Should -Be 'Cleared' }
    }

    # Failure goal: nonzero native exit codes must retain their original handling, even
    # without stderr. In particular, failed create/delete must prevent dependent actions.
    It 'handles nonzero exit from <Operation> (silent: <Silent>) without false success' -ForEach $failures {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            FailOperation = $Operation; EmitWarning = -not $Silent; SilentFailure = $Silent
        }
        $result.Calls[-1].Operation | Should -Be $Operation
        $result.Messages | Should -Not -Match 'SUCCESS:'
        if ($Kind -eq 'single' -or $Operation -in @('account', 'inventory', 'vcenter')) {
            $result.ExitCode | Should -Be 7
            $result.Failure | Should -Not -BeNullOrEmpty
            $result.Failure.Exception.Message | Should -Match '(?i)failed'
        } else {
            # The batch script deliberately exits 1 after reporting any failed or unverified VM.
            $result.ExitCode | Should -Be 1
            $result.Failure | Should -BeNullOrEmpty
            $expected = if ($Operation -eq 'verify') { 'Unverified' } else { 'Error' }
            $result.Rows[0].Status | Should -Be $expected
        }
        if ($Operation -eq 'create') { @($result.Calls.Operation) | Should -Not -Contain 'delete' }
        if ($Operation -eq 'delete') { @($result.Calls.Operation) | Should -Not -Contain 'verify' }
    }

    # Only a genuine not-found permits recreation; auth/network failures must never do so.
    It 'does not mistake a failed existence probe for a missing resource: <ErrorText>' -ForEach @(
        @{ ErrorText = 'AuthenticationFailed: token expired' }
        @{ ErrorText = 'AuthorizationFailed: access denied' }
        @{ ErrorText = 'ConnectionError: network unavailable' }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ FailOperation = 'machine'; ErrorText = $ErrorText }
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        if ($Kind -eq 'batch') {
            $result.Rows[0].Status | Should -Be 'Error'
            $result.Rows[0].Detail | Should -Match ([regex]::Escape($ErrorText))
        } else {
            $result.Failure.Exception.Message | Should -Match ([regex]::Escape($ErrorText))
        }
    }

    It 'recreates a genuinely missing machine before deleting it' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ MachineExists = $false }
        $result.Failure | Should -BeNullOrEmpty
        @($result.Calls.Operation) | Should -Not -Contain 'kind'
        @($result.Calls.Operation) | Should -Not -Contain 'show'
        @($result.Calls.Operation) | Should -Contain 'create'
        $result.Messages | Should -Match 'SUCCESS:'
    }

    It 'skips recreation when the machine and VM instance already exist' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ InstanceExists = $true }
        $result.Failure | Should -BeNullOrEmpty
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Contain 'delete'
        $result.Messages | Should -Match 'SUCCESS:'
    }

    # Parsing goal: relaxing native stderr handling must not relax PowerShell exceptions.
    # Bad setup JSON must terminate before writes; bad verification JSON cannot undo a
    # completed delete, but must never produce a cleared result.
    It 'still rejects malformed JSON after a successful <Operation> command' -ForEach @(
        @{ Operation = 'inventory' }
        @{ Operation = 'vcenter' }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ MalformedOperation = $Operation }
        $result.ExitCode | Should -Be 0
        $result.Failure | Should -Not -BeNullOrEmpty
        $result.Failure.FullyQualifiedErrorId | Should -Match 'ConvertFromJson|ConvertFrom-Json'
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
    }

    It 'reports malformed verification JSON after deletion without claiming success' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ MalformedOperation = 'verify' }
        ($result.Calls[-3..-1].Operation -join ',') | Should -Be 'create,delete,verify'
        $result.Messages | Should -Not -Match 'SUCCESS:'
        if ($Kind -eq 'batch') {
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            $result.Rows[0].Status | Should -Be 'Error'
            $result.Rows[0].Detail | Should -Match '(?i)json'
        } else {
            $result.Failure.FullyQualifiedErrorId | Should -Match 'ConvertFromJson|ConvertFrom-Json'
        }
    }

    # Validation goal: invalid IDs and missing prerequisites must fail before mutation,
    # even though the fake CLI itself succeeds. Assert the precise reason and safe stop.
    It 'rejects an invalid vCenter ID before any CLI call' {
        $result = Invoke-StaleLinkScenario @runParameters -VCenterId '/not-a-vcenter'
        $result.Failure.Exception.Message | Should -Match 'Invalid vCenter resource ID'
        $result.Calls.Count | Should -Be 0
    }

    It 'rejects a vCenter without a custom location before mutation' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ CustomLocation = '' }
        $result.Failure.Exception.Message | Should -Match 'Could not read extendedLocation.name'
        $result.Calls[-1].Operation | Should -Be 'vcenter'
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        $result.Rows.Count | Should -Be 0
    }

    It 'rejects an unparseable stale machine ID before probing or changing resources' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ ManagedResourceId = '/invalid-machine-id' }
        @($result.Calls.Operation) | Should -Not -Contain 'machine'
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        if ($Kind -eq 'batch') {
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            $result.Rows[0].Status | Should -Be 'Error'
            $result.Rows[0].Detail | Should -Match 'Could not parse subscription/resource group/machine name'
        } else {
            $result.Failure.Exception.Message | Should -Match 'Could not parse subscription/resource group/machine name'
        }
    }

    # Ownership goal: a foreign machine kind is a safety block, not a CLI exception.
    # Neither script may recreate or delete a resource owned by another private cloud.
    It 'blocks a foreign machine kind without creating or deleting' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ MachineKind = 'SCVMM' }
        $result.Failure | Should -BeNullOrEmpty
        $result.Messages | Should -Match 'InvalidMachineKindInput'
        $result.Messages | Should -Not -Match 'SUCCESS:'
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        @($result.Calls.Operation) | Should -Not -Contain 'verify'
        if ($Kind -eq 'batch') { $result.Rows[0].Status | Should -Be 'Blocked' }
    }

    # Consent goal: read-only modes and declined prompts must not cause destructive calls.
    It 'does not create or delete resources in check-only/report-only mode' {
        $result = Invoke-StaleLinkScenario @runParameters -ReadOnly
        $result.Failure | Should -BeNullOrEmpty
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        if ($Kind -eq 'batch') { $result.Rows[0].Status | Should -Be 'WouldClear' }
        else { $result.Messages | Should -Match '\-CheckOnly was specified' }
    }

    It 'does not act after the initial confirmation is declined' {
        $result = Invoke-StaleLinkScenario @runParameters -Decision 'abort'
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        if ($Kind -eq 'batch') { $result.Failure.Exception.Message | Should -Match 'Aborted by the operator' }
        else { $result.Messages | Should -Match 'Aborted' }
    }

    # Only the single-VM script offers these per-VM decisions. Register the tests there
    # rather than reporting misleading skips for prompts the batch script never shows.
    if ($Kind -eq 'single') {
        It 'does not act after the change confirmation is declined' {
            $result = Invoke-StaleLinkScenario @runParameters -Decision 'decline-change'
            $result.Failure | Should -BeNullOrEmpty
            @($result.Calls.Operation) | Should -Not -Contain 'create'
            @($result.Calls.Operation) | Should -Not -Contain 'delete'
            $result.Messages | Should -Match 'Aborted - no resources'
        }

        It 'does not delete an existing machine when the operator chooses keep' {
            $result = Invoke-StaleLinkScenario @runParameters -Decision 'keep'
            $result.Failure | Should -BeNullOrEmpty
            @($result.Calls.Operation) | Should -Not -Contain 'delete'
            $result.Messages | Should -Match 'Keeping the existing Arc VM'
        }
    }

    It 'leaves an already empty link untouched' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ NoStaleLink = $true }
        $result.Failure | Should -BeNullOrEmpty
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        if ($Kind -eq 'batch') { $result.Rows[0].Status | Should -Be 'NoStaleLink' }
    }

    It 'does not report a cleared link when verification returns a link' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ StillLinked = $true }
        $result.Failure | Should -BeNullOrEmpty
        $result.Messages | Should -Not -Match 'SUCCESS:'
        $result.Messages | Should -Match "managedResourceId is still 'still-linked'"
        if ($Kind -eq 'batch') { $result.Rows[0].Status | Should -Be 'StillLinked' }
    }

    if ($Kind -eq 'batch') {
        # Batch success goal: reuse setup reads while processing each VM independently,
        # and persist one correctly attributed Cleared row per VM in input order.
        It 'clears every VM in a successful batch with one shared inventory read' {
            $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ VmNames = @('vm-a', 'vm-b') }
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            @($result.Calls | Where-Object Operation -eq 'inventory').Count | Should -Be 1
            @($result.Calls | Where-Object Operation -eq 'vcenter').Count | Should -Be 1
            ($result.Rows.VmName -join ',') | Should -Be 'vm-a,vm-b'
            ($result.Rows.Status -join ',') | Should -Be 'Cleared,Cleared'
            foreach ($vm in @('vm-a', 'vm-b')) {
                $vmCalls = @($result.Calls | Where-Object { $_.Name -eq $vm -and $_.Operation -in @('create', 'delete', 'verify') })
                ($vmCalls.Operation -join ',') | Should -Be 'create,delete,verify'
                ($result.Rows | Where-Object VmName -eq $vm).MachineName | Should -Be $vm
            }
        }

        # Setup exceptions affect the entire batch: an offline bridge must stop before
        # inventory or mutation, rather than generate misleading per-VM success rows.
        It 'stops the batch when the resource bridge is disconnected' {
            $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ ConnectionStatus = 'Disconnected' }
            $result.Failure.Exception.Message | Should -Match "connectionStatus 'Disconnected'"
            ($result.Calls.Operation -join ',') | Should -Be 'account,vcenter'
            $result.Rows.Count | Should -Be 0
        }

        # Recovery goal: a per-VM error must preserve the failed VM's status, suppress
        # unsafe follow-up calls, and still clear the next VM. The overall exit stays 1.
        It 'continues after <Operation> fails for the first VM' -ForEach @(
            @{ Operation = 'machine' }
            @{ Operation = 'kind' }
            @{ Operation = 'show' }
            @{ Operation = 'delete' }
            @{ Operation = 'verify' }
        ) {
            $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
                VmNames = @('vm-a', 'vm-b'); FailOperation = $Operation; FailVm = 'vm-a'
            }
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            ($result.Rows.VmName -join ',') | Should -Be 'vm-a,vm-b'
            $expectedStatus = if ($Operation -eq 'verify') { 'Unverified' } else { 'Error' }
            $result.Rows[0].Status | Should -Be $expectedStatus
            $result.Rows[1].Status | Should -Be 'Cleared'
            $firstVmCalls = @($result.Calls | Where-Object { $_.Name -eq 'vm-a' })
            $firstVmCalls[-1].Operation | Should -Be $Operation
            $secondVmWrites = @($result.Calls | Where-Object { $_.Name -eq 'vm-b' -and $_.Operation -in @('create', 'delete', 'verify') })
            ($secondVmWrites.Operation -join ',') | Should -Be 'create,delete,verify'
        }

        # A PowerShell parsing exception must be isolated just like a native failure.
        # The first deletion happened, but only the second VM may be reported as cleared.
        It 'continues after malformed verification JSON for the first VM' {
            $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
                VmNames = @('vm-a', 'vm-b'); MalformedOperation = 'verify'; MalformedVm = 'vm-a'
            }
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            ($result.Rows.VmName -join ',') | Should -Be 'vm-a,vm-b'
            ($result.Rows.Status -join ',') | Should -Be 'Error,Cleared'
            $result.Rows[0].Detail | Should -Match '(?i)json'
            foreach ($vm in @('vm-a', 'vm-b')) {
                $writes = @($result.Calls | Where-Object { $_.Name -eq $vm -and $_.Operation -in @('create', 'delete', 'verify') })
                ($writes.Operation -join ',') | Should -Be 'create,delete,verify'
            }
        }

        It 'continues to the next VM after a create failure, without deleting the failed VM' {
            $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
                VmNames = @('vm-a', 'vm-b'); FailOperation = 'create'; FailVm = 'vm-a'
            }
            $result.Failure | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            $result.Rows.Count | Should -Be 2
            $result.Rows[0].Status | Should -Be 'Error'
            $result.Rows[1].Status | Should -Be 'Cleared'
            @($result.Calls | Where-Object { $_.Operation -eq 'delete' -and $_.Name -eq 'vm-a' }).Count | Should -Be 0
            @($result.Calls | Where-Object { $_.Operation -eq 'delete' -and $_.Name -eq 'vm-b' }).Count | Should -Be 1
        }
    }
}

Describe 'Standalone CLI setup (native error preference: <NativeErrors>)' -ForEach $setupRuns -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $runParameters = @{ Kind = 'setup'; NativeErrors = $NativeErrors }
    }

    # Setup owns local tooling only: upgrade the CLI, add/update just the two required
    # extensions, and verify commands load. Exact sequences also exclude Azure operations.
    It 'installs or updates required extensions without touching scvmm: <Scenario>' -ForEach @(
        @{
            Scenario = 'all extensions already installed'
            Installed = @('connectedvmware', 'connectedmachine', 'scvmm'); Unavailable = @()
            ExpectedRepairs = 'extension-update:connectedvmware,extension-update:connectedmachine'
        }
        @{
            Scenario = 'missing connectedvmware'
            Installed = @('connectedmachine', 'scvmm'); Unavailable = @()
            ExpectedRepairs = 'extension-add:connectedvmware,extension-update:connectedmachine'
        }
        @{
            Scenario = 'both required extensions absent'
            Installed = @(); Unavailable = @()
            ExpectedRepairs = 'extension-add:connectedvmware,extension-add:connectedmachine'
        }
        @{
            Scenario = 'missing connectedmachine'
            Installed = @('connectedvmware', 'scvmm'); Unavailable = @()
            ExpectedRepairs = 'extension-update:connectedvmware,extension-add:connectedmachine'
        }
        @{
            Scenario = 'connectedvmware installed but unrecognized'
            Installed = @('connectedvmware', 'connectedmachine', 'scvmm'); Unavailable = @('connectedvmware')
            ExpectedRepairs = 'extension-update:connectedvmware,extension-update:connectedmachine'
        }
        @{
            Scenario = 'connectedmachine installed but unrecognized'
            Installed = @('connectedvmware', 'connectedmachine', 'scvmm'); Unavailable = @('connectedmachine')
            ExpectedRepairs = 'extension-update:connectedvmware,extension-update:connectedmachine'
        }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            InstalledExtensions = $Installed; UnavailableExtensions = $Unavailable
        }
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.Preference | Should -Be 'Stop'
        $result.Diagnostics | Should -Match 'SyntaxWarning'
        $result.Messages | Should -Match 'Azure CLI setup completed'
        $result.Rows.Count | Should -Be 0
        ($result.Calls[0].Arguments -join '|') | Should -Be 'upgrade|--yes|--all|false'
        $repairs = @($result.Calls | Where-Object { $_.Operation -in @('extension-add', 'extension-update') })
        (($repairs | ForEach-Object { "$($_.Operation):$($_.Name)" }) -join ',') | Should -Be $ExpectedRepairs
        @($repairs.Name) | Should -Not -Contain 'scvmm'
        foreach ($call in $repairs) {
            ($call.Arguments -join '|') | Should -Be "extension|$($call.Operation -replace '^extension-')|--name|$($call.Name)|-o|none"
        }
        ($result.Calls.Operation -join ',') | Should -Be ("upgrade,extension-list," + ($repairs.Operation -join ',') + ',extension-help,extension-help')
        ($result.Calls[-2].Arguments -join '|') | Should -Be 'connectedvmware|vm|show|--help'
        ($result.Calls[-1].Arguments -join '|') | Should -Be 'connectedmachine|show|--help'
    }

    It 'also completes setup without stderr warnings' {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{ EmitWarning = $false }
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.Diagnostics | Should -BeNullOrEmpty
        $result.Messages | Should -Match 'Azure CLI setup completed'
    }

    # Upgrade failure must preserve the exit code and stop before extension changes.
    It 'stops immediately when Azure CLI upgrade fails (silent: <Silent>)' -ForEach @(
        @{ Silent = $false }
        @{ Silent = $true }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            FailOperation = 'upgrade'; SilentFailure = $Silent; EmitWarning = -not $Silent
        }
        $result.Failure.Exception.Message | Should -Match 'Failed to upgrade Azure CLI'
        $result.Failure.Exception.Message | Should -Match 'az upgrade --yes --all false'
        $result.ExitCode | Should -Be 7
        ($result.Calls.Operation -join ',') | Should -Be 'upgrade'
        $result.Messages | Should -Not -Match 'setup completed'
    }

    # Both installation and update failures must stop before verification or completion.
    It 'stops when extension <Action> fails for <Extension>' -ForEach @(
        @{ Extension = 'connectedvmware'; Action = 'add'; Installed = @() }
        @{ Extension = 'connectedmachine'; Action = 'add'; Installed = @() }
        @{ Extension = 'connectedvmware'; Action = 'update'; Installed = @('connectedvmware', 'connectedmachine') }
        @{ Extension = 'connectedmachine'; Action = 'update'; Installed = @('connectedvmware', 'connectedmachine') }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            InstalledExtensions = $Installed; FailOperation = "extension-$Action"; FailVm = $Extension
        }
        $result.Failure.Exception.Message | Should -Match "Failed to $Action Azure CLI extension '$Extension'"
        $result.Failure.Exception.Message | Should -Match "az extension $Action --name $Extension"
        $result.ExitCode | Should -Be 7
        $result.Calls[-1].Operation | Should -Be "extension-$Action"
        $result.Calls[-1].Name | Should -Be $Extension
        @($result.Calls.Operation) | Should -Not -Contain 'extension-help'
        (@($result.Calls | Where-Object Operation -notlike 'extension-*').Operation -join ',') | Should -Be 'upgrade'
        $result.Messages | Should -Not -Match 'setup completed'
    }

    # An installer may return success without fixing an incompatible command.
    # Command verification must catch this rather than reporting false readiness.
    It 'stops when setup leaves <Extension> unavailable' -ForEach @(
        @{ Extension = 'connectedvmware' }
        @{ Extension = 'connectedmachine' }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides @{
            UnavailableExtensions = @($Extension); RepairIneffective = $true
        }
        $result.Failure.Exception.Message | Should -Match 'still unavailable after extension setup'
        $result.Failure.Exception.Message | Should -Match $Extension
        $result.ExitCode | Should -Be 2
        $result.Calls[-1].Operation | Should -Be 'extension-help'
        $result.Calls[-1].Name | Should -Be $Extension
        @($result.Calls | Where-Object Operation -eq 'extension-update').Count | Should -Be 2
        $result.Messages | Should -Not -Match 'setup completed'
    }

    # A failed or unreadable extension list is not an empty installation.
    It 'rejects an unusable CLI extension list: <Scenario>' -ForEach @(
        @{ Scenario = 'native failure'; Overrides = @{ FailOperation = 'extension-list' } }
        @{ Scenario = 'malformed JSON'; Overrides = @{ MalformedOperation = 'extension-list' } }
    ) {
        $result = Invoke-StaleLinkScenario @runParameters -Overrides $Overrides
        $result.Failure | Should -Not -BeNullOrEmpty
        ($result.Calls.Operation -join ',') | Should -Be 'upgrade,extension-list'
        if ($Scenario -eq 'native failure') {
            $result.Failure.Exception.Message | Should -Match 'Failed to list installed Azure CLI extensions'
        } else {
            $result.Failure.FullyQualifiedErrorId | Should -Match 'ConvertFromJson|ConvertFrom-Json'
        }
    }
}
