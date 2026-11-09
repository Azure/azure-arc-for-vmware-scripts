# Diagnostic logs for Azure Arc-enabled VMware vSphere

`arcvmware-collect-logs.ps1` collects VMware operator logs and, optionally, the
Arc Resource Bridge diagnostic bundle. It writes the results locally for you to review
before sharing with support. The script does not upload the collected logs.

## What is collected?

| Output | Normal run | With `-SkipApplianceLogs` |
|---|---|---|
| Current VMware operator container logs | Last 24 hours by default; change with `-SinceHours`. | Same. |
| Previous operator container logs | Collected if Kubernetes retains a previous container's logs. | Same. |
| Arc Resource Bridge diagnostic bundle | Collected using `az arcappliance logs vmware`. | Not collected. |
| Summary, manifest and local ZIP | Created; `-NoArchive` disables only the ZIP. | Same, with the appliance step marked `Skipped`. |

Operator-only collection retains the separately collected operator logs, but omits the
broader appliance diagnostics. Previous logs are not restricted by `-SinceHours`.
Collect promptly: Kubernetes may no longer retain logs even within the requested window.

**Privacy:** logs can contain resource names, addresses, vCenter errors and other customer
information. Captured operator text and command results receive best-effort secret redaction.
The appliance bundle and interactive appliance CLI output are **not redacted by this script**.
Review all files before sharing.

The script does not request vCenter/ESXi support bundles or separately export inventories,
Kubernetes resource bodies, other containers' logs, workstation diagnostics or configuration.
**The appliance bundle's contents are determined by the installed Azure CLI extension**;
the script does not filter that bundle or guarantee which files it excludes.
The appliance CLI may use vCenter credentials, so do not assume the full collection never
connects to vCenter.

## Before you start

Run from the resource bridge deployment management machine in an interactive console or RDP
session. Follow your organization's PowerShell execution policy. Remote PowerShell is not
supported by `az arcappliance`.

| Requirement | When needed |
|---|---|
| PowerShell 5.1 or 7+ | Always. |
| `kubectl` and access to the bridge's Kubernetes API | Operator logs. |
| Azure CLI with the `arcappliance` extension and an authorized Azure login | Downloading bridge credentials or collecting the appliance bundle. |
| vCenter address and vSphere credentials | The appliance CLI may prompt for them; not needed for operator-only collection. |
| Network access to the appliance VM on SSH TCP port 22 | Appliance bundle collection. |

The script does not install tools, sign in automatically or deploy resources.

## Quick start: collect both log sources

In Azure portal, open the **Arc Resource Bridge** resource and copy its **Resource ID**
from Properties or JSON View. It has this format:

```text
/subscriptions/<subscription-id>/resourceGroups/<group>/providers/Microsoft.ResourceConnector/appliances/<name>
```

Open PowerShell in the directory containing the script. Replace the placeholders below:

```powershell
az login --tenant '<bridge-tenant-id>'
.\arcvmware-collect-logs.ps1 -ResourceBridgeId '<full-resource-bridge-id>'
```

If already signed in to the correct tenant with the required access, no new login is needed.
The script selects the **bridge's subscription**, downloads temporary kubeconfig and log
credentials, collects the appliance bundle, then collects operator logs and creates a ZIP.
No appliance IP or kubeconfig path is needed.

**Answer any CLI prompts for vCenter address, vSphere username and password in the console.**
Downloaded bridge credentials do not necessarily remove these prompts. The public
[CLI reference](https://learn.microsoft.com/cli/azure/arcappliance/logs#az-arcappliance-logs-vmware)
describes the vSphere account as the one used for on-premises infrastructure guest management.
Enter the password only at the interactive prompt, never in the script or command line.

Appliance collection can take several minutes. Prompts and CLI progress remain visible;
operator collection starts after that command exits. On completion, the script prints the
output folder and ZIP paths.

`-VCenterResourceId` is **optional**: it only records a customer-supplied Azure resource ID
in the summary. It does not supply vSphere credentials, select the subscription or verify
the vCenter's association with the bridge. The two resource IDs may belong to different
subscriptions; bridge access always uses the bridge's subscription.

## Collect operator logs only

To omit the appliance bundle and avoid vSphere credential prompts:

```powershell
.\arcvmware-collect-logs.ps1 -ResourceBridgeId '<full-resource-bridge-id>' `
    -SkipApplianceLogs
```

Azure login is still required because the script downloads the bridge's kubeconfig.

If you already have a bridge kubeconfig, use its actual file path instead:

```powershell
.\arcvmware-collect-logs.ps1 -KubeConfig '.\my-bridge-appliance.kubeconfig' `
    -SkipApplianceLogs
```

This second command needs `kubectl`, but **no Azure CLI or Azure login**.
The script always uses the supplied or downloaded kubeconfig, never the workstation's default
Kubernetes context. A supplied kubeconfig bypasses credential download; a missing file is
reported rather than replaced automatically.

### During incomplete onboarding

Automatic credential retrieval may be unavailable before the bridge is registered in Azure.
If deployment has produced a kubeconfig, use the existing-file command above.
If the appliance or operator does not exist yet, the script reports missing logs rather than
collecting another source instead.

To also request the appliance bundle with an existing kubeconfig, omit `-SkipApplianceLogs`.
Sign in to Azure and select the intended subscription first, or supply `-ResourceBridgeId`
to select its subscription. The CLI also needs existing deployment log keys in its default
credentials directory: `C:\ProgramData\kva.ssh` on Windows or `~/.kva/.ssh` on Linux/macOS.
The script does not download credentials when `-KubeConfig` is supplied.

## Commands the script runs

| Command | Purpose |
|---|---|
| `az account set --subscription ...` | Select the bridge subscription when its resource ID is supplied and Azure access is needed. The subscription remains selected afterward. |
| `az account show` | Check that the active subscription is enabled and matches the bridge ID, if supplied. |
| `az arcappliance get-credentials` | Download kubeconfig and log keys when a bridge ID is supplied without `-KubeConfig` and a log source is enabled. |
| `az arcappliance logs vmware` | Collect the appliance bundle; omitted with `-SkipApplianceLogs`. |
| `kubectl get pods` | Read only matching operator pod names and namespaces for discovery. |
| `kubectl logs` | Read current and previous logs from the `vmware-operator` container on each discovered pod. |

All `kubectl` calls use an explicit kubeconfig and a 60-second request timeout.
With an existing kubeconfig and `-SkipApplianceLogs`, no Azure commands run.
With `-SkipOperatorLogs`, no `kubectl` commands run. Skipping both sources runs neither tool.

Downloaded credentials are kept in a unique temporary directory outside the output and
deleted when the script finishes, including after collection failures. Supplied kubeconfig
files are not deleted. If the process is forcibly terminated, temporary credentials may
remain; securely remove only the corresponding `arcvmware-credentials-*` directory.
The script does not copy these credentials into its output or ZIP.

## Check the results

Read `SUMMARY.md` and `manifest.json` first. Available steps continue after individual
collection failures, so the script finishing does **not** mean every source succeeded.
`Collected` means the command succeeded; also inspect the actual files.

```text
01-appliance/
    arcappliance-logs.txt       CLI outcome or collection error, not an interactive transcript
    appliance-log-bundle/      Bundle generated by the CLI
02-operator/
    <namespace>-<pod>-current.log
    <namespace>-<pod>-previous.log
SUMMARY.md
manifest.json
```

Files may be absent when a source is skipped or prerequisites are missing.
The output folder is named `arcvmware-logs-<timestamp>` by default, with a ZIP alongside it.
Use `-OutDir` to choose a **new or empty** directory; existing output is not reused.

After a run, substitute the printed output folder path:

```powershell
$out = '<output-folder-path>'
Get-Content (Join-Path $out 'manifest.json') -Raw |
    ConvertFrom-Json | Format-Table Description, Status, Detail -AutoSize
Get-ChildItem -LiteralPath $out -Recurse -File
```

For a full successful run, confirm the appliance bundle contains files and the current
operator logs contain diagnostic lines. Missing previous logs can be normal when the
container has not restarted. Check the ZIP as well: do not share kubeconfig or log keys.

### Local smoke test without appliance access

```powershell
$out = Join-Path $env:TEMP ("arcvmware-smoke-" + [guid]::NewGuid().ToString('N'))
.\arcvmware-collect-logs.ps1 -SkipApplianceLogs -SkipOperatorLogs -OutDir $out
Get-Content (Join-Path $out 'manifest.json') -Raw |
    ConvertFrom-Json | Format-Table Description, Status, Detail -AutoSize
Test-Path "$out.zip"
```

Expect two `Skipped` entries, a summary, manifest, empty source directories and a ZIP.
This checks local reporting and packaging only, not live log access or redaction.

## Troubleshooting

| Problem | What to check |
|---|---|
| Appliance collection is waiting | Look for CLI prompts in the console and answer them. On a command failure, read the CLI error there; its interactive transcript is not saved. |
| Appliance logs cannot be collected | Check management-machine requirements and SSH TCP port 22 access to the appliance VM. See the public troubleshooting guide below. |
| `AuthorizationFailed` or a subscription mismatch | Sign in to the bridge's tenant with access to its subscription and the required permissions. An enabled subscription alone does not prove sufficient access. Refresh your login after permission changes if needed. |
| Python `SyntaxWarning` messages | These are separate from authorization failures. Account-check stderr is kept separate from JSON output. Read the command outcome and any accompanying error. |
| No operator pods or logs | Check that the appliance/operator exists and that the kubeconfig can access its Kubernetes API. |

To isolate a source, rerun with a fresh output folder and `-SkipApplianceLogs` or
`-SkipOperatorLogs`.

## Parameters

| Parameter | Effect |
|---|---|
| `-ResourceBridgeId <id>` | Full bridge ARM resource ID; selects its subscription when Azure access is needed and downloads credentials unless `-KubeConfig` is supplied. |
| `-VCenterResourceId <id>` | Optional vCenter ARM resource ID, recorded as support-case context only. |
| `-KubeConfig <path>` | Existing bridge kubeconfig; bypasses credential download. |
| `-SinceHours <n>` | Current operator log window, 1-8760 hours; default 24. Does not limit previous logs or the appliance bundle. |
| `-IncidentId <id>` | Optional support case label in the summary. |
| `-SkipApplianceLogs` | Omit the appliance bundle. |
| `-SkipOperatorLogs` | Omit operator logs. |
| `-NoArchive` | Do not create a ZIP; keep the output folder, summary and manifest. |
| `-OutDir <path>` | Use a new or empty output directory. |

## Public documentation

- [Collect logs from the Arc resource bridge](https://learn.microsoft.com/azure/azure-arc/vmware-vsphere/administer-arc-vmware#collect-logs-from-the-arc-resource-bridge).
- [Azure CLI resource bridge commands](https://learn.microsoft.com/cli/azure/arcappliance).
- [Azure CLI appliance log commands](https://learn.microsoft.com/cli/azure/arcappliance/logs).
- [Troubleshoot Azure Arc resource bridge: log collection](https://learn.microsoft.com/azure/azure-arc/resource-bridge/troubleshoot-resource-bridge#logs-collection).
- [Kubernetes container logs](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/).
