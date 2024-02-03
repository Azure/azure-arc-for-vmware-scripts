# VMware Batch Enablement Script

This PowerShell script, [`arcvmware-batch-enablement.ps1`](./arcvmware-batch-enablement.ps1), is designed to enable Virtual Machines (VMs) in a vCenter in batch. It's particularly useful for large-scale operations where you need to manage hundreds or thousands of VMs.

## Features

- Creates a log file (`vmware-batch.log`) for tracking the script's operation.
- Generates a list of Azure portal links to all deployments created (`all-deployments-<timestamp>.txt`).
- Creates ARM deployment files (`vmw-dep-<timestamp>-<batch>.json`).
- Can enable up to 200 VMs in a single ARM deployment if guest management is enabled, else 400 VMs.
- Supports running as a cron job to enable all VMs in a vCenter.
- Allows for service principal authentication to Azure for automation.

## Prerequisites

Before running this script, please install:

- Azure CLI: Install it from [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli).
- The `connectedvmware` extension for Azure CLI: Install it by running `az extension add --name connectedvmware`.

## Important Notes

While using the script, it's crucial to pay attention to the comments marked with "NOTE". These comments provide important instructions or information about the script's operation. Here are the key points to note:

1. **Customizing the VM Name**: In [this line](./arcvmware-batch-enablement.ps1#L303)
The script uses the function `normalizeMoName` to generate a normalized name for the VM, and then appends the `moRefId` to it. If you want to customize how the VM names are generated, you can modify this line of code.

    ```powershell
    # NOTE: Modify the following line to customize the VM name.
    $vmName = normalizeMoName $nonManagedVMs[$i].moName
    $vmName += "-$moRefId"
    ```

2. **Setting the Username and Password**: In [this line](./arcvmware-batch-enablement.ps1#L316), there's a note about setting the username and password for the guest management resource. You can modify these lines to use different credentials or to fetch the credentials from environment variables or a secure store.

    ```powershell
    # NOTE: Set the username and password here. You can also use environment variables to fetch the username and password.
    $username = "Administrator"
    $password = "Password"
    ```

3. **Pretty Printing the ARM Deployment Files**: In [this line](./arcvmware-batch-enablement.ps1#L336), there's a note about pretty printing the ARM deployment files. If you want the deployment files to be formatted with indentation for easier reading, you can uncomment these lines.

    ```powershell
    # NOTE: Uncomment the following lines if you want to pretty print the ARM deployment files.
    # $deployment = ConvertFrom-Json | ConvertTo-Json -Depth 100
    ```

4. **Setting Sleep Time Between Deployments**: In [this line](./arcvmware-batch-enablement.ps1#L353), there's a note about setting the sleep time between deployments. If you want to introduce a delay between each deployment, you can modify the number of seconds in the `Start-Sleep` command.

    ```powershell
    # NOTE: set sleep time between deployments here, if needed.
    Start-Sleep -Seconds 5
    ```

## Usage

1. Download the script to your local machine.
2. Open a PowerShell terminal and navigate to the directory containing the script.
3. Run the script with the required parameters. For example:

```powershell
.\arcvmware-batch-enablement.ps1 -VCenterId "<vCenterId>" -EnableGuestManagement -VMCountPerDeployment 3 -DryRun
```

Replace `<vCenterId>` with the ARM ID of your vCenter.

## Parameters

- `VCenterId`: The ARM ID of the vCenter where the VMs are located.
- `EnableGuestManagement`: If this switch is specified, the script will enable guest management on the VMs.
- `VMCountPerDeployment`: The number of VMs to enable per ARM deployment. The maximum value is 200 if guest management is enabled, else 400.
- `DryRun`: If this switch is specified, the script will only create the ARM deployment files. Else, the script will also deploy the ARM deployments.

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
