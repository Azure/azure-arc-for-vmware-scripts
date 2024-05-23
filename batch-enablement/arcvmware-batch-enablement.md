# VMware Batch Enablement Script

This PowerShell script, [`arcvmware-batch-enablement.ps1`](./arcvmware-batch-enablement.ps1), is designed to enable Virtual Machines (VMs) in a vCenter in batch. It's particularly useful for large-scale operations where you need to manage hundreds or thousands of VMs.

> [!IMPORTANT]
> When guest management is enabled, the script saves your guest VM credential in a file `.do-not-reveal-guestvm-credential.json` in the same directory where the script is present.
> Please ensure that you delete this file after the script has completed its execution.
> The ARM template uses this file as the parameter to enable guest management on the VMs.

> [!IMPORTANT]
> The VMInventoryFile needs to have atleast the following columns:
> - vmName
> - moRefId


## Features

- Creates a log file (`arcvmware-batch-enablement.log`) for tracking the script's operation.
- Generates a list of Azure portal links to all deployments created (`all-deployments-<timestamp>.txt`).
- Creates ARM deployment files (`vmw-dep-<timestamp>-<batch>.json`).
- Can enable up to 200 VMs in a single ARM deployment if guest management is enabled, else 400 VMs.
- Supports running as a cron job to enable all VMs in a vCenter.
- Allows for service principal authentication to Azure for automation.

## Prerequisites

Before running this script, please install:

- Azure CLI: Install it from [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli).
- The `connectedvmware` extension for Azure CLI: Install it by running `az extension add --name connectedvmware`.

## Usage

1. First generate the VM inventory file by running the script [export-vcenter-vms.ps1](./export-vcenter-vms.ps1). The readme for the script is [here](./export-vcenter-vms.md).
2. Download the script to your local machine.
3. Open a PowerShell terminal and navigate to the directory containing the script.
4. Run the script with the required parameters. First, you can run it in default mode to check the summary of the azure operations that will be performed. If you are satisfied with the summary, you can re-run the script with the `-Execute` switch to perform the azure operations.

> [!IMPORTANT]
> The VMInventoryFile needs to have at least the following columns:
> - vmName
> - moRefId

```powershell
./arcvmware-batch-enablement.ps1 -VCenterId /subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter -EnableGuestManagement -VMInventoryFile vms.json
```
> [!NOTE]
> To get the detailed help for the script, run `Get-Help .\arcvmware-batch-enablement.ps1 -Detailed`.

## Parameters

- `VCenterId`: The ARM ID of the vCenter where the VMs are located.
- `VMInventoryFile`: The path to the file containing the VM inventory. The file should be in CSV or JSON format and contain at least the following columns: `vmName` and `moRefId`.
- `EnableGuestManagement`: If this switch is specified, the script will enable guest management on the VMs.
- `VMCredential`: The credentials to be used for enabling guest management on the VMs. If not specified, the script will prompt for the credentials.
- `Execute`: If this switch is specified, the script will deploy the created ARM templates. If not specified, the script will only create the ARM templates and provide the summary.

## Running as a Cron Job

You can set up this script to run as a cron job using the Windows Task Scheduler. Here's a sample script to create a scheduled task:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-File "C:\Path\To\vmware-batch-enable.ps1" -VCenterId "<vCenterId>" -EnableGuestManagement -VMCountPerDeployment 3 -DryRun'
$trigger = New-ScheduledTaskTrigger -Daily -At 3am
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "EnableVMs"
```

Replace `<vCenterId>` with the ARM ID of your vCenter.

To unregister the task, run the following command:

```powershell
Unregister-ScheduledTask -TaskName "EnableVMs"
```

## Support

If you encounter any issues or have any questions about this script, please open an issue in this repository.

## License

This script is provided under the MIT License. See the LICENSE file for details.
