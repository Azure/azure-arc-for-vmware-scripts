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
The script downloads credentials for the explicitly identified resource bridge, or uses an
explicitly supplied kubeconfig. It never uses the workstation's default Kubernetes context.
Downloaded kubeconfig and log keys are stored in a unique temporary directory **outside the
collection output**, passed only to the appliance CLI and kubectl, and deleted when the script
finishes, including after collection failures. If the process is forcibly terminated, temporary
credentials may remain; delete the corresponding `arcvmware-credentials-*` directory securely.

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
| Azure CLI with the `arcappliance` extension | Downloads bridge credentials and collects the appliance bundle. |
| Azure login in the bridge's tenant, with appropriate permissions | Allows subscription selection, credential retrieval and appliance CLI operations. |
| `kubectl` | Discovers operator pods and reads their logs. |
| Arc Resource Bridge ARM resource ID | Identifies the subscription, resource group and bridge for credential retrieval. |

Missing prerequisites and command failures are reported in `SUMMARY.md` and `manifest.json`.
Other available collection steps continue. The script does not install tools, log in automatically
or deploy resources.

## Usage

### Recommended: supply the Azure resource IDs

In Azure portal, open the **Arc Resource Bridge** resource and copy its **Resource ID** from
Properties or JSON View. Do the same for the **vCenter** resource. These IDs can belong to
different subscriptions. The vCenter ID is optional support-case context only; the script does
not query vCenter or verify its association with the supplied bridge.

```powershell
az login --tenant '<bridge-tenant-id>'
.\arcvmware-collect-logs.ps1 `
    -VCenterResourceId '/subscriptions/<vcenter-subscription-id>/resourceGroups/<vcenter-group>/providers/Microsoft.ConnectedVMwarevSphere/vCenters/<vcenter-name>' `
    -ResourceBridgeId '/subscriptions/<bridge-subscription-id>/resourceGroups/<bridge-group>/providers/Microsoft.ResourceConnector/appliances/<bridge-name>'
```

Replace the placeholders with the actual IDs. The script:

1. Selects the **bridge's subscription** with `az account set`.
2. Downloads its kubeconfig and log keys with `az arcappliance get-credentials`.
3. Collects the appliance bundle and current/previous VMware operator logs.
4. Creates a local ZIP and deletes the temporary credentials.

No appliance IP or kubeconfig path is needed for this normal flow. Optional `-SinceHours 48`
changes the current operator log window; `-IncidentId` labels the support case.

### Incomplete onboarding: use an existing kubeconfig

If the bridge has not been registered in Azure, automatic credential retrieval may not be
available. Use the appliance kubeconfig created by deployment, if it exists:

```powershell
.\arcvmware-collect-logs.ps1 -KubeConfig .\my-bridge-appliance.kubeconfig `
    -SinceHours 48 -IncidentId 123456789
```

Replace the example path with the actual file path. In this mode, no credentials are downloaded.
For appliance bundle collection, the CLI also needs the existing deployment log keys in its
default credentials directory (`C:\ProgramData\kva.ssh` on Windows; `~/.kva/.ssh` on Linux/macOS).
Log in and select the bridge's intended subscription yourself when omitting `-ResourceBridgeId`.
Operator-only collection (`-SkipApplianceLogs`) with an existing kubeconfig needs no Azure login.

Only available log sources can be collected. If the appliance or operator does not yet exist,
the script reports that limitation rather than collecting workstation or vCenter data instead.

Run promptly after an issue: previous container logs can be lost on another
restart, and current logs are limited by Kubernetes retention even within the requested window.

### Azure CLI context and authorization

The appliance CLI uses Azure even when accessing logs over SSH. With `-ResourceBridgeId`, the
script **changes the default Azure CLI subscription to the bridge's subscription and leaves it
selected**. It does not change your login or infer the tenant from the resource ID.
Sign in to the correct bridge tenant first.

The script checks `az account show` for an enabled subscription and passes its ID explicitly to
credential retrieval and appliance collection. It never saves the account response.
Malformed resource IDs are rejected before collection. Context or credential failures are
reported; an explicitly supplied kubeconfig still allows independent operator collection.

An enabled subscription does **not** prove sufficient permissions or fresh credentials.
`AuthorizationFailed` for `Microsoft.ResourceConnector/telemetryconfig/read` or
`Microsoft.Resources/subscriptions/providers/read` needs the correct subscription/tenant
and permissions, or credential refresh after an access change. The script reports nonzero CLI
exits as failures instead of treating a context check as proof of access.

Python `SyntaxWarning` output from an installed CLI extension is separate from authorization
failure. Successful command stderr is shown as a warning, not mixed into JSON stdout.

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

Use an authorized registered test bridge on the deployment workstation:

```powershell
$out = Join-Path $env:TEMP ("arcvmware-live-" + [guid]::NewGuid().ToString('N'))
.\arcvmware-collect-logs.ps1 -ResourceBridgeId '<full-bridge-arm-resource-id>' `
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
Also check that credential retrieval is `Collected` and that no kubeconfig or log keys appear in
the output/ZIP. The script continues after individual collection failures, so process exit status
alone is not a complete success check.

To isolate a failing source, repeat with a fresh output directory and `-SkipApplianceLogs`
or `-SkipOperatorLogs`. Review all files for customer information before sharing, including
the unredacted appliance bundle.

## Parameters

| Parameter | Effect |
|---|---|
| `-ResourceBridgeId <id>` | Full ARB ARM ID; selects its subscription and downloads temporary credentials when no kubeconfig is supplied. |
| `-VCenterResourceId <id>` | Optional full vCenter ARM ID, recorded as customer-supplied case context only. |
| `-KubeConfig <path>` | Existing appliance kubeconfig; bypasses credential download and is never copied. |
| `-SinceHours <n>` | Current operator log window; defaults to 24 hours. Does not control the appliance bundle or previous logs. |
| `-IncidentId <id>` | Optional support case or IcM identifier. |
| `-SkipApplianceLogs` | Collect operator logs only. |
| `-SkipOperatorLogs` | Collect the appliance bundle only. |
| `-NoArchive` | Leave files uncompressed. |
| `-OutDir <path>` | Choose a new or empty output directory. |
