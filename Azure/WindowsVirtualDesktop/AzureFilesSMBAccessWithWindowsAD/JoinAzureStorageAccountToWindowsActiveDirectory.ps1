#Join Azure Storage Account to Windows Active Directory
#And Enable AD DS authentication for your Azure file shares

#Download Azure Files Script (AzFilesHybrid):
#https://github.com/Azure-Samples/azure-files-samples/releases

Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser

.\CopyToPSPath.ps1

Import-Module -Name AzFilesHybrid
Install-Module Az
Import-Module Az
Connect-AzAccount

$SubscriptionId = "000000-000000-000000-000000-00000" # Change SubscriptionId to your SubscriptionId
$ResourceGroupName = "RG-PRD-WVD-01" # Change Resource Group name to your Resource Group name
$StorageAccountName = "uniqueavdusrp01" # Change Storage Account name to your Storage Account name
Select-AzSubscription -SubscriptionId $SubscriptionId

Join-AzStorageAccountForAuth `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -DomainAccountType "ComputerAccount" `
        -OrganizationalUnitDistinguishedName   "OU=Shared,OU=AVD,OU=Azure,DC=domain,DC=com" # Change DistinguishedName to your DistinguishedName
