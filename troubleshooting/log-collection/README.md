# Diagnostic log collection for Azure Arc-enabled VMware vSphere

`arcvmware-collect-logs.ps1` collects **only VMware operator logs and the Arc Resource Bridge
diagnostic bundle** for a support case or IcM. It reads logs without changing Azure,
Kubernetes or vCenter resources. Files are written locally; nothing is uploaded automatically.

## Collection and privacy boundary

| Collected | Scope |
|---|---|
| Current VMware operator logs | Only the `vmware-operator` container in pods matching `control-plane=vmware-operator`; default last 24 hours, without a correlation-ID filter. |
| Previous VMware operator logs | The previous instance of that same container, if Kubernetes still retains its logs. |
| Appliance diagnostic bundle | Output of the supported `az arcappliance logs vmware` command. Bundle contents are determined by the installed Azure CLI extension. |
| Collection results | Optional case identifier, timestamp, log window and per-step success, failure or missing prerequisites. |

The script **does not connect to vCenter or ESXi** and does not request their logs or support
bundles. It does not collect Azure resource inventories, VM inventories, Kubernetes custom-resource
bodies, deployments, pod descriptions, events, Secret inventories or contents, other containers'
logs, workstation details, proxy settings, network probes, onboarding script logs, `kva.log`,
appliance YAML files, kubeconfig contents or SSH keys.

Pod names and namespaces are read only to locate the operator and name its log files.
An explicit kubeconfig is required: the script never searches for credentials or uses the
workstation's default Kubernetes context.

**This is source minimization, not a guarantee that logs contain no customer data.**
Operator and appliance logs can themselves contain vCenter error messages, resource names,
addresses and other customer identifiers. The script applies best-effort redaction of common
password/token fields, URL credentials, bearer tokens, JWTs and PEM private keys to captured
operator text and CLI output. It does not remove all identifiers or arbitrary sensitive text.

**The appliance bundle is generated directly by the Azure CLI and is not redacted by this
script.** Review the entire output, including the bundle, under your organization's privacy
and support-data-sharing requirements before attaching it to a case.

## Where to run it

Use the customer's resource bridge deployment workstation, in a console session or RDP.
Remote PowerShell is not supported by `az arcappliance`.

| Prerequisite | Purpose |
|---|---|
| PowerShell 5.1 or 7+ | Runs the script. |
| Azure CLI with the `arcappliance` extension | Collects the appliance bundle. |
| Appliance log SSH key under `$HOME/.kva/.ssh` (`logkey`, `logkey.pub`) | Used by the appliance CLI; never copied by this script. |
| `kubectl` and an explicitly supplied appliance kubeconfig | Discovers operator pods and reads their logs. |
| Appliance kubeconfig or appliance VM IP | Locates the appliance for bundle collection. |

Missing prerequisites and command failures are reported in `SUMMARY.md` and `manifest.json`.
Other permitted collection steps continue. The script does not install tools, obtain credentials
or deploy resources.

## Usage

### Appliance logs without a kubeconfig

Supply the appliance VM IP to collect its diagnostic bundle. Operator logs require a kubeconfig
and are reported as missing in this example.

```powershell
.\arcvmware-collect-logs.ps1 -ApplianceVmIp 10.0.0.50 -IncidentId 123456789
```

### Appliance and operator logs

```powershell
.\arcvmware-collect-logs.ps1 -KubeConfig .\my-bridge-appliance.kubeconfig `
    -SinceHours 48 -IncidentId 123456789
```

The same commands apply during onboarding and after onboarding. Only available log sources can
be collected; if neither the appliance nor the operator exists yet, the script records that
limitation rather than collecting workstation or vCenter data instead.

Run promptly after an issue: previous container logs can be lost on another
restart, and current logs are limited by Kubernetes retention even within the requested window.

## Output

```text
01-appliance/
    arcappliance-logs.txt          CLI output or collection error
    appliance-log-bundle/         Bundle produced by the appliance CLI
02-operator/
    <namespace>-<pod>-current.log
    <namespace>-<pod>-previous.log
SUMMARY.md                        Collection scope, results and privacy warning
manifest.json                     Machine-readable per-step results
```

A ZIP is created alongside the output directory unless `-NoArchive` is supplied.
The output directory must be new or empty, so an old inventory/configuration dump cannot
accidentally be included. Previous output is never cleaned or reused automatically.

## Checking the script

Run these commands from the directory containing the script. Each test uses a unique output
directory. Follow your organization's PowerShell execution policy; do not disable it to run tests.

### Local smoke test (no appliance access)

```powershell
$out = Join-Path $env:TEMP ("arcvmware-smoke-" + [guid]::NewGuid().ToString('N'))
.\arcvmware-collect-logs.ps1 -SkipApplianceLogs -SkipOperatorLogs -OutDir $out
Get-Content (Join-Path $out 'manifest.json') -Raw |
    ConvertFrom-Json | Format-Table Description, Status, Detail -AutoSize
Test-Path "$out.zip"
```

Expect two `Skipped` entries, a summary and manifest, empty source directories, and a ZIP.
This checks local reporting and packaging only, not log access or redaction.

### Test against a resource bridge

Use an authorized test appliance and its explicit kubeconfig on the deployment workstation:

```powershell
$out = Join-Path $env:TEMP ("arcvmware-live-" + [guid]::NewGuid().ToString('N'))
.\arcvmware-collect-logs.ps1 -KubeConfig .\my-bridge-appliance.kubeconfig `
    -SinceHours 1 -OutDir $out
Get-Content (Join-Path $out 'manifest.json') -Raw |
    ConvertFrom-Json | Format-Table Description, Status, Detail -AutoSize
Get-ChildItem (Join-Path $out '01-appliance\appliance-log-bundle') -Recurse -File
Get-ChildItem (Join-Path $out '02-operator') -File
Get-Content (Join-Path $out 'SUMMARY.md')
Test-Path "$out.zip"
```

Confirm the appliance bundle contains files, current operator logs contain diagnostic lines,
and the ZIP contains only the documented output. Previous-log collection can fail normally
when no previous container exists; check its recorded error. `Collected` means the command
succeeded, not that every expected artifact is present. Inspect the files as well as the manifest.
The script continues after individual collection failures, so process exit status alone is
not a complete success check.

To isolate a failing source, repeat with a fresh output directory and `-SkipApplianceLogs`
or `-SkipOperatorLogs`. Review all files for customer information before sharing, including
the unredacted appliance bundle.

## Parameters

| Parameter | Effect |
|---|---|
| `-KubeConfig <path>` | Explicit appliance kubeconfig, used for access only. |
| `-ApplianceVmIp <ip>` | Appliance bundle access when no valid kubeconfig is supplied. |
| `-SinceHours <n>` | Current operator log window; defaults to 24 hours. Does not control the appliance bundle or previous logs. |
| `-IncidentId <id>` | Optional support case or IcM identifier. |
| `-SkipApplianceLogs` | Collect operator logs only. |
| `-SkipOperatorLogs` | Collect the appliance bundle only. |
| `-NoArchive` | Leave files uncompressed. |
| `-OutDir <path>` | Choose a new or empty output directory. |
