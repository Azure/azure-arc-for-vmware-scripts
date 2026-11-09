<#
.SYNOPSIS
    Collects only VMware operator logs and the Arc Resource Bridge diagnostic bundle.

.DESCRIPTION
    Run on the customer's resource bridge deployment workstation using a console session or RDP.
    The script reads logs without modifying Azure, Kubernetes or vCenter resources. It does not
    connect to vCenter, collect vCenter/ESXi logs, or dump inventory or configuration.

    Missing prerequisites and collection failures are recorded. During onboarding, the bridge
    or operator may not exist yet.

    Operator text and command output pass through best-effort secret redaction. The appliance
    bundle is produced by the Azure CLI and is NOT redacted by this script. Both log sources
    may contain customer identifiers or vCenter error messages. Review before sharing.

.PARAMETER VCenterResourceId
    vCenter ARM resource ID for support-case context only. No vCenter data is requested.
.PARAMETER ResourceBridgeId
    Arc Resource Bridge ARM resource ID. Selects its Azure CLI subscription and downloads
    temporary kubeconfig and log credentials when -KubeConfig is not supplied.
.PARAMETER KubeConfig
    Existing resource bridge kubeconfig, for example during incomplete onboarding.
    Used for access, never copied into output. No credentials are downloaded when supplied.
.PARAMETER SinceHours
    Look-back window for current operator logs; default 24. Previous logs use retained history.
.PARAMETER IncidentId
    Optional support case or IcM identifier recorded in the summary.
.PARAMETER OutDir
    A new or empty directory. Nonempty directories are rejected to avoid including old data.
.PARAMETER SkipApplianceLogs
    Skip the Azure CLI appliance diagnostic bundle.
.PARAMETER SkipOperatorLogs
    Skip operator log collection.
.PARAMETER NoArchive
    Leave the output folder uncompressed.

.EXAMPLE
    .\arcvmware-collect-logs.ps1 `
        -VCenterResourceId '/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.ConnectedVMwarevSphere/vCenters/<name>' `
        -ResourceBridgeId '/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.ResourceConnector/appliances/<name>'
.EXAMPLE
    .\arcvmware-collect-logs.ps1 -KubeConfig .\my-bridge-appliance.kubeconfig `
        -SinceHours 48 -IncidentId 123456789
#>

param(
    [string]$VCenterResourceId,
    [string]$ResourceBridgeId,
    [string]$KubeConfig,
    [ValidateRange(1, 8760)][int]$SinceHours = 24,
    [string]$IncidentId,
    [string]$OutDir,
    [switch]$SkipApplianceLogs,
    [switch]$SkipOperatorLogs,
    [switch]$NoArchive
)

$ErrorActionPreference = 'Stop'
$idPrefix = '^/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourceGroups/([^/?#\s]+)/providers/'
if ($VCenterResourceId -and $VCenterResourceId -notmatch ($idPrefix + 'Microsoft\.ConnectedVMwarevSphere/vCenters/([^/?#\s]+)$')) {
    throw 'VCenterResourceId must be a full Microsoft.ConnectedVMwarevSphere/vCenters ARM resource ID.'
}
$bridgeSubscription = $null
$bridgeGroup = $null
$bridgeName = $null
if ($ResourceBridgeId) {
    if ($ResourceBridgeId -notmatch ($idPrefix + 'Microsoft\.ResourceConnector/appliances/([^/?#\s]+)$')) {
        throw 'ResourceBridgeId must be a full Microsoft.ResourceConnector/appliances ARM resource ID.'
    }
    $bridgeSubscription, $bridgeGroup, $bridgeName = $Matches[1], $Matches[2], $Matches[3]
}
$startedUtc = (Get-Date).ToUniversalTime()
if (-not $OutDir) {
    $OutDir = Join-Path (Get-Location).Path ("arcvmware-logs-" + $startedUtc.ToString('yyyyMMdd-HHmmss'))
}
if (Test-Path -LiteralPath $OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        throw "Output path is not a directory: $OutDir"
    }
    if (Get-ChildItem -LiteralPath $OutDir -Force | Select-Object -First 1) {
        throw "Output directory must be empty to avoid including previously collected data: $OutDir"
    }
}
$null = New-Item -ItemType Directory -Force -Path $OutDir
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$dirs = @{
    Appliance = '01-appliance'
    Operator = '02-operator'
}
foreach ($dir in $dirs.Values) {
    $null = New-Item -ItemType Directory -Path (Join-Path $OutDir $dir)
}
$script:Manifest = New-Object System.Collections.ArrayList
$script:ResolvedKubeConfig = $null
$credentialsDir = $null

function Protect-Secret {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $sensitiveKey = 'password|passwd|pwd|secret|clientsecret|client_secret|token|accesskey|account_key|accountkey|sharedkey|shared_key|apikey|api_key|credential|privatekey|private_key|sshprivatekey|sas|connectionstring|bootstrapkey'
    $Text = [regex]::Replace($Text, "(?im)^(\s*[""']?(?:$sensitiveKey)[""']?\s*[:=]\s*)(?!null\b)(.+)$", '$1<redacted>')
    $Text = [regex]::Replace($Text, "(?i)([""'](?:$sensitiveKey)[""']\s*:\s*)(""[^""]*"")", '$1"<redacted>"')
    $Text = [regex]::Replace($Text, '(?i)(https?|ftp)://[^:/\s]+:[^@/\s]+@', '$1://<redacted>:<redacted>@')
    $Text = [regex]::Replace($Text, '(?i)bearer\s+[A-Za-z0-9._\-]{20,}', 'Bearer <redacted>')
    $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]*', '<redacted-jwt>')
    $Text = [regex]::Replace($Text, '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', '<redacted-private-key>')
    return $Text
}

function Add-Result {
    param([string]$Section, [string]$File, [string]$Description, [string]$Status, [string]$Detail)
    $null = $script:Manifest.Add([pscustomobject]@{
        Section = $dirs[$Section]
        File = $File
        Description = $Description
        Status = $Status
        Detail = (Protect-Secret $Detail)
    })
    if ($Status -in @('Failed', 'Missing', 'Skipped')) {
        Write-Warning "$Description : $Status - $(Protect-Secret $Detail)"
    }
}

function Invoke-Collect {
    param([string]$Section, [string]$FileName, [string]$Description, [scriptblock]$Script)
    Write-Host "Collecting: $Description"
    $path = Join-Path (Join-Path $OutDir $dirs[$Section]) $FileName
    $status = 'Collected'
    $detail = ''
    try {
        $text = (& $Script | Out-String)
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = '(no output)'
            $status = 'Empty'
        }
    }
    catch {
        $status = 'Failed'
        $detail = $_.Exception.Message
        $text = "ERROR: $detail"
    }
    Set-Content -LiteralPath $path -Value (Protect-Secret $text) -Encoding UTF8
    Add-Result $Section $FileName $Description $status $detail
}

function Invoke-Az {
    $azArgs = $args
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        # Keep native warnings separate from stdout, especially for JSON preflight responses.
        $output = & { $ErrorActionPreference = 'Continue'; & az @azArgs 2> $stderrPath }
        $exitCode = $LASTEXITCODE
        $stderr = Get-Content -LiteralPath $stderrPath -Raw
        if ($exitCode -ne 0) {
            throw "az failed (exit $exitCode): $($output | Out-String) $stderr"
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Warning (Protect-Secret $stderr)
        }
        $output
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force
    }
}

function Invoke-Kubectl {
    $kubeArgs = @('--kubeconfig', $script:ResolvedKubeConfig, '--request-timeout', '60s') + $args
    $output = & { $ErrorActionPreference = 'Continue'; & kubectl @kubeArgs 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed (exit $LASTEXITCODE): $($output | Out-String)"
    }
    $output
}

Write-Host 'Collecting VMware operator and Arc Resource Bridge logs only.'
Write-Warning 'Logs can contain customer information. The appliance bundle is not redacted by this script. Review all output before sharing.'

if ($KubeConfig) {
    if (Test-Path -LiteralPath $KubeConfig -PathType Leaf) {
        $script:ResolvedKubeConfig = (Resolve-Path -LiteralPath $KubeConfig).Path
    }
    else {
        Write-Warning 'The supplied kubeconfig does not exist; logs cannot be collected with it.'
    }
}

try {
    $account = $null
    $contextError = $null
    $needsCredentials = $ResourceBridgeId -and -not $KubeConfig -and (-not $SkipApplianceLogs -or -not $SkipOperatorLogs)
    if (-not $SkipApplianceLogs -or $needsCredentials) {
        if (Get-Command az -ErrorAction SilentlyContinue) {
            try {
                if ($bridgeSubscription) {
                    Write-Host "Selecting Arc Resource Bridge subscription $bridgeSubscription."
                    $null = Invoke-Az account set --subscription $bridgeSubscription
                }
                $account = (Invoke-Az account show --query '{id:id,state:state}' -o json | Out-String) | ConvertFrom-Json
                if (-not $account.id -or $account.state -ne 'Enabled') {
                    throw 'Azure CLI did not return an enabled subscription.'
                }
                if ($bridgeSubscription -and $account.id -ne $bridgeSubscription) {
                    throw "Azure CLI subscription mismatch: active $($account.id), expected $bridgeSubscription."
                }
            }
            catch {
                $contextError = "Azure CLI context check failed. Run az login --tenant <bridge-tenant-id> with an account that can access the bridge subscription, then retry. $($_.Exception.Message)"
            }
        }
        else {
            $contextError = 'Azure CLI is not installed.'
        }
    }

    if ($needsCredentials) {
        try {
            if ($contextError) { throw $contextError }
            $credentialsDir = Join-Path ([System.IO.Path]::GetTempPath()) ("arcvmware-credentials-" + [guid]::NewGuid().ToString('N'))
            Write-Host 'Downloading temporary Arc Resource Bridge credentials.'
            $null = Invoke-Az arcappliance get-credentials --name $bridgeName --resource-group $bridgeGroup `
                --subscription $bridgeSubscription --credentials-dir $credentialsDir --yes
            $kubeFiles = @(Get-ChildItem -LiteralPath $credentialsDir -Filter '*kubeconfig*' -File -Recurse)
            if ($kubeFiles.Count -ne 1) {
                throw "Expected one downloaded kubeconfig, found $($kubeFiles.Count)."
            }
            $script:ResolvedKubeConfig = $kubeFiles[0].FullName
            Add-Result Appliance '' 'Resource bridge credential retrieval' Collected 'Temporary credentials are excluded from the output and deleted after collection.'
        }
        catch {
            Add-Result Appliance '' 'Resource bridge credential retrieval' Failed $_.Exception.Message
        }
    }

    if ($SkipApplianceLogs) {
        Add-Result Appliance '' 'Appliance log bundle' Skipped 'Disabled by -SkipApplianceLogs.'
    }
    elseif (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Add-Result Appliance '' 'Appliance log bundle' Missing 'Azure CLI is not installed.'
    }
    elseif (-not $script:ResolvedKubeConfig) {
        Add-Result Appliance '' 'Appliance log bundle' Missing 'No appliance kubeconfig is available. Supply -ResourceBridgeId or an existing -KubeConfig; see credential retrieval errors if present.'
    }
    else {
        $applianceLogDir = Join-Path (Join-Path $OutDir $dirs.Appliance) 'appliance-log-bundle'
        $null = New-Item -ItemType Directory -Path $applianceLogDir
        Invoke-Collect Appliance 'arcappliance-logs.txt' 'Azure CLI appliance log collection' {
            if ($contextError) { throw $contextError }
            Write-Host "Appliance log collection will use Azure CLI subscription $($account.id)."
            'Azure CLI context verified. This does not verify all appliance log permissions.'
            $logArgs = @('arcappliance', 'logs', 'vmware', '--kubeconfig', $script:ResolvedKubeConfig,
                '--out-dir', $applianceLogDir, '--subscription', $account.id)
            if ($credentialsDir) { $logArgs += @('--credentials-dir', $credentialsDir) }
            Invoke-Az @logArgs
        }
    }

    if ($SkipOperatorLogs) {
        Add-Result Operator '' 'VMware operator logs' Skipped 'Disabled by -SkipOperatorLogs.'
    }
    elseif (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Add-Result Operator '' 'VMware operator logs' Missing 'kubectl is not installed.'
    }
    elseif (-not $script:ResolvedKubeConfig) {
        Add-Result Operator '' 'VMware operator logs' Missing 'No appliance kubeconfig is available. Supply -ResourceBridgeId or an existing -KubeConfig; the bridge may not be registered yet.'
    }
    else {
        $operatorPods = @()
        try {
            # Read only pod identifiers for discovery; never save pod bodies or cluster configuration.
            $podLines = Invoke-Kubectl get pods -A -l control-plane=vmware-operator -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}'
            $operatorPods = @(($podLines | Out-String) -split "`n" | Where-Object { $_.Trim() })
            if ($operatorPods.Count -eq 0) {
                Add-Result Operator '' 'VMware operator discovery' Missing 'No pods matched control-plane=vmware-operator.'
            }
        }
        catch {
            Add-Result Operator '' 'VMware operator discovery' Failed $_.Exception.Message
        }
        foreach ($entry in $operatorPods) {
            $parts = $entry.Trim() -split '\s+'
            if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[a-z0-9][a-z0-9.-]*$' -or $parts[1] -notmatch '^[a-z0-9][a-z0-9.-]*$') {
                Add-Result Operator '' 'VMware operator discovery' Failed 'Unexpected pod identifier response.'
                continue
            }
            $ns, $pod = $parts
            $filePrefix = "$ns-$pod"
            Invoke-Collect Operator "$filePrefix-current.log" 'Current VMware operator container logs' {
                Invoke-Kubectl logs -n $ns $pod -c vmware-operator --timestamps=true --since="${SinceHours}h"
            }
            Invoke-Collect Operator "$filePrefix-previous.log" 'Previous VMware operator container logs' {
                Invoke-Kubectl logs -n $ns $pod -c vmware-operator --timestamps=true --previous
            }
        }
    }

    $script:Manifest | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $OutDir 'manifest.json') -Encoding UTF8
    $summary = New-Object System.Text.StringBuilder
    $null = $summary.AppendLine('# Arc-enabled VMware diagnostic logs')
    $null = $summary.AppendLine()
    if ($IncidentId) { $null = $summary.AppendLine("Incident: $(Protect-Secret $IncidentId)") }
    if ($VCenterResourceId) { $null = $summary.AppendLine("vCenter resource ID (customer supplied): $VCenterResourceId") }
    if ($ResourceBridgeId) { $null = $summary.AppendLine("Resource bridge ID (customer supplied): $ResourceBridgeId") }
    $null = $summary.AppendLine("Started UTC: $($startedUtc.ToString('u'))")
    $null = $summary.AppendLine("Current operator log window: $SinceHours hours. Previous logs use retained history.")
    $null = $summary.AppendLine()
    $null = $summary.AppendLine('Only VMware operator logs and the Azure CLI appliance diagnostic bundle are requested.')
    $null = $summary.AppendLine('The appliance bundle is not redacted by this script. Logs may include customer identifiers or vCenter errors. Review all files before sharing.')
    $null = $summary.AppendLine()
    foreach ($row in $script:Manifest) {
        $null = $summary.AppendLine("- $($row.Description): $($row.Status). $($row.Detail)")
    }
    $null = $summary.AppendLine()
    $null = $summary.AppendLine('During onboarding, no logs may be available until the appliance or operator exists. Missing previous logs can mean the container has not restarted.')
    Set-Content -LiteralPath (Join-Path $OutDir 'SUMMARY.md') -Value $summary.ToString() -Encoding UTF8

    if (-not $NoArchive) {
        Compress-Archive -LiteralPath $OutDir -DestinationPath "$OutDir.zip" -Force
        Write-Host "Archive: $OutDir.zip"
    }
    Write-Host "Folder: $OutDir"
}
finally {
    if ($credentialsDir -and (Test-Path -LiteralPath $credentialsDir)) {
        Remove-Item -LiteralPath $credentialsDir -Recurse -Force
    }
}
