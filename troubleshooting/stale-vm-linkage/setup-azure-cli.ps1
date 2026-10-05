#Requires -Version 5.1
<#
.SYNOPSIS
    Prepares Azure CLI for the stale-VM-link troubleshooting scripts.

.DESCRIPTION
    Upgrades Azure CLI, installs missing connectedvmware/connectedmachine extensions,
    and updates those extensions when already installed. Checks that the required
    commands load successfully before reporting completion.
    Does not update unrelated extensions such as scvmm, select a subscription,
    or read, create, or delete Azure resources.

.NOTES
    Azure CLI must already be installed and available as 'az' on PATH.
    Internet access and permission to update the local installation are required;
    the Azure CLI installer may require an administrator PowerShell session.
    Run this script separately before either clear-stale-vm-link script.

.EXAMPLE
    .\setup-azure-cli.ps1
#>

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') was not found on PATH. Install Azure CLI, open a new PowerShell session, then rerun this setup script."
}

# Do not let the CLI upgrade update every installed extension.
Write-Host "Updating Azure CLI..."
& { $ErrorActionPreference = 'Continue'; az upgrade --yes --all false }
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upgrade Azure CLI. Resolve the installer error (administrator permissions may be required), run 'az upgrade --yes --all false', then retry this script."
}

$extensionsJson = & { $ErrorActionPreference = 'Continue'; az extension list --query "[].name" -o json }
if ($LASTEXITCODE -ne 0) { throw "Failed to list installed Azure CLI extensions. Check the Azure CLI installation before retrying." }
$installedExtensions = @($extensionsJson | ConvertFrom-Json | ForEach-Object { $_ })

foreach ($extension in @('connectedvmware', 'connectedmachine')) {
    $action = if ($extension -in $installedExtensions) { 'update' } else { 'add' }
    Write-Host "Running: az extension $action --name $extension"
    & { $ErrorActionPreference = 'Continue'; az extension $action --name $extension -o none }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to $action Azure CLI extension '$extension'. Resolve the CLI error and rerun 'az extension $action --name $extension' before retrying this script."
    }
}

# A successful installer exit is not enough: commands must now load successfully.
$requiredCommands = @(
    @('connectedvmware', 'vm', 'show', '--help'),
    @('connectedmachine', 'show', '--help')
)
foreach ($commandArgs in $requiredCommands) {
    & { $ErrorActionPreference = 'Continue'; az @commandArgs | Out-Null }
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command '$($commandArgs -join ' ')' is still unavailable after extension setup. Check Azure CLI compatibility and the extension installation before retrying."
    }
}

Write-Host "Azure CLI setup completed. Run the stale-link script separately when ready." -ForegroundColor Green
