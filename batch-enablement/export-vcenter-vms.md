# Export the properties of VMs in VMware vCenter

This PowerShell script, [`export-vcenter-vms.ps1`](./export-vcenter-vms.ps1), exports the properties of VMs in VMware vCenter to a CSV file, or JSON file in the same directory as the script. To connect to the vCenter, it prefers PowerCLI, but if it's not installed, it uses govc.

For each VM, it exports the following properties:
- Connection State
- Guest ID
- Guest Family
- Guest Full Name
- Host Name
- MoRef ID
- Power State
- Tools Version
- Tools Version Status
- Tools Running Status
- VM Name

The script asks for the credentials interactively if they are not provided as parameters.