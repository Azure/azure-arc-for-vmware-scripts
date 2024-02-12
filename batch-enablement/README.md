# Arc for VMWare Batch enablement

## Step 1

Export the vCenter inventory VMs to a CSV or JSON file. This can be done by running the script [export-vcenter-vms.ps1](./export-vcenter-vms.ps1). The readme for the script is [here](./export-vcenter-vms.md).

## Step 2

The exported inventory VM data (CSV or JSON) can be filtered and split into multiple files as per the requriement. For each file, we'll use a single user account to enable the VMs to Arc in Step 3. So, if you are using different user accounts, you can split the file into multiple files.

```powershell
./export-vcenter-vms.ps1 -VCenterId /subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter
```

## Step 3

Run the script [arcvmware-batch-enablement.ps1](./arcvmware-batch-enablement.ps1) to enable the VMs to Arc. The readme for the script is [here](./arcvmware-batch-enablement.md).
First, you can run it in default mode to check the summary of the azure operations that will be performed. If you are satisfied with the summary, you can re-run the script with the `-Execute` switch to perform the azure operations.

```powershell
./arcvmware-batch-enablement.ps1 -VCenterId /subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/contoso-rg/providers/Microsoft.ConnectedVMwarevSphere/vcenters/contoso-vcenter -EnableGuestManagement -VMInventoryFile vms.json
```