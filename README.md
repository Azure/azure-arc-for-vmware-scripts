# Project

> [!WARNING]
> **This repository is deprecated and is no longer maintained.**
>
> The Azure Arc for VMware team has stopped maintaining the scripts in this repository. No further
> fixes or feature work will be delivered here. The content is kept for historical reference only
> and is provided as-is, without support. Please do not take a new dependency on these scripts, and
> use the officially supported
> [Azure Arc-enabled VMware vSphere](https://learn.microsoft.com/azure/azure-arc/vmware-vsphere/)
> tooling and documentation instead.

## Removed scripts

The helper script `batch-enablement/powercli-export-vms.ps1` has been **removed** from this
repository. It was an optional convenience helper for exporting vCenter inventory and no longer
met our current engineering standards. As the repository is deprecated, the script was removed
rather than updated.

If you need the same inventory data, query vCenter directly with a supported
[VMware PowerCLI](https://developer.broadcom.com/powercli) or
[`govc`](https://github.com/vmware/govmomi) workflow, or use the Azure Resource Graph based
inventory that the batch enablement script produces on its own.

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
