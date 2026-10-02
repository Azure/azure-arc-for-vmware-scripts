#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Offline regression tests for both stale-link scripts on Windows.
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
}

BeforeAll {
    $testsRoot = $PSScriptRoot
    function Invoke-StaleLinkScenario {
        param(
            [string]$Kind,
            [bool]$NativeErrors,
            [hashtable]$Overrides = @{},
            [switch]$ReadOnly,
            [string]$Decision = 'proceed'
        )

        $directory = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $configPath = Join-Path $directory.FullName 'config.json'
        $callsPath = Join-Path $directory.FullName 'calls.jsonl'
        $reportPath = Join-Path $directory.FullName 'report.csv'
        $config = @{
            CallsPath = $callsPath; EmitWarning = $true
            MachineExists = $true; InstanceExists = $false
            VmNames = @('vm-a'); ErrorText = 'AuthorizationFailed: simulated failure'
        }
        foreach ($key in $Overrides.Keys) { $config[$key] = $Overrides[$key] }
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

        $fileName = if ($Kind -eq 'batch') { 'clear-stale-vm-link-batch.ps1' } else { 'clear-stale-vm-link.ps1' }
        $file = Join-Path (Split-Path $testsRoot -Parent) $fileName
        $fixture = Join-Path $testsRoot 'fixtures\az.cmd'
        $parameters = @{ VCenterId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.ConnectedVMwarevSphere/vCenters/v' }
        if ($Kind -eq 'batch') {
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

    It 'keeps warning-only stderr visible and JSON/TSV usable through create, delete, and verification' {
        $result = Invoke-StaleLinkScenario @runParameters
        $result.Failure | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.Preference | Should -Be 'Stop'
        $result.Diagnostics | Should -Match 'SyntaxWarning'
        $result.Diagnostics | Should -Match 'simulated connectedvmware SDK warning'
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

    It 'does not act after the change confirmation is declined' -Skip:($Kind -ne 'single') {
        $result = Invoke-StaleLinkScenario @runParameters -Decision 'decline-change'
        $result.Failure | Should -BeNullOrEmpty
        @($result.Calls.Operation) | Should -Not -Contain 'create'
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        $result.Messages | Should -Match 'Aborted - no resources'
    }

    It 'does not delete an existing machine when the operator chooses keep' -Skip:($Kind -ne 'single') {
        $result = Invoke-StaleLinkScenario @runParameters -Decision 'keep'
        $result.Failure | Should -BeNullOrEmpty
        @($result.Calls.Operation) | Should -Not -Contain 'delete'
        $result.Messages | Should -Match 'Keeping the existing Arc VM'
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
