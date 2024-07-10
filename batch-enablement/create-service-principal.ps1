# TODO: Set the role name to the desired role for the service principal
$roleName = "contributor"

$subscriptionID = (az account show --query id -o tsv).Trim()
if (!$subscriptionID) {
  Write-Host "No subscription ID found. Exiting."
  exit 1
}

# prompt user if this subscription ID is to be used.
$confirm = Read-Host "SPN will be created in the subscription with ID $subscriptionID. Do you want to continue? (y/n)"
$confirm = $confirm.ToLower()
if ($confirm -ne "y" -or $confirm -ne "yes") {
  Write-Host "Please set the subscription ID using 'az account set --subscription <subscription name or ID>' and run the script again. Exiting."
  exit 1
}

# prompt user for resource group name
$resourceGroup = Read-Host "Enter the name of the resource group where the SPN will be created"
if (!$resourceGroup) {
  Write-Host "No resource group name provided. Exiting."
  exit 1
}
# check if the resource group exists
$resourceGroupExists = az group exists --name $resourceGroup -o tsv
if ($resourceGroupExists -ne "true") {
  Write-Host "Resource group $resourceGroup does not exist. Exiting..."
  exit 1
}
$servicePrincipalName = "enablevm-cronjob-" + $resourceGroup

# ask for SPN name, if empty input, keep it unchanged.
$spnNameInput = Read-Host "Enter the name of the service principal to be created. Press Enter to use the default name: $servicePrincipalName"
if ($spnNameInput) {
  $servicePrincipalName = $spnNameInput
}

Write-Host "Creating SP for RBAC with name $servicePrincipalName, with role $roleName and in scopes /subscriptions/$subscriptionID/resourceGroups/$resourceGroup"
az ad sp create-for-rbac --name $servicePrincipalName --role $roleName --scopes "/subscriptions/$subscriptionID/resourceGroups/$resourceGroup"
Write-Host @"
Please take a note of the applicationId, password and tenantId for the service principal.
The password cannot be retrieved from azure later.

To login using the service principal, use the following command:
az login --service-principal -u <applicationId> -p <password> --tenant <tenantId>
"@
