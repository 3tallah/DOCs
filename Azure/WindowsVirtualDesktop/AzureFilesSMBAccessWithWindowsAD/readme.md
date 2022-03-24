# Azure Files SMB Access with Windows AD | Azure Storage Account with NTFS


### All in One Script: [Link](https://github.com/3tallah/DOCs/blob/master/Azure/WindowsVirtualDesktop/AzureFilesSMBAccessWithWindowsAD/JoinAzureStorageAccountToWindowsActiveDirectory.ps1) 

#### Part one: enable AD DS authentication for your Azure file shares

```
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser
Install-PackageProvider -Name NuGet -Force

cd downloads\AzFilesHybrid
.\CopyToPSPath.ps1
Import-Module -Name AzFilesHybrid

Install-Module Az
Import-Module Az
Connect-AzAccount
```

#### Part two: assign share-level permissions to an identity


To assign an Azure role to an Azure AD identity, using the Azure portal, follow these steps:
1. In the Azure portal, go to your file share, or create a file share.
2. Select Access Control (IAM).
3. Select Add a role assignment
4. In the Add role assignment blade, select the appropriate built-in role (Storage File Data SMB Share Reader, Storage File Data SMB Share Contributor) from the Role list. Leave Assign access to at the default setting: Azure AD user, group, or service principal. Select the target Azure AD identity by name or email address. The selected Azure AD identity must be a hybrid identity and cannot be a cloud only identity. This means that the same identity is also represented in AD DS.
5. Select Save to complete the role assignment operation.


#### Part three: configure directory and file level permissions over SMB

Use Windows File Explorer to grant full permission to all directories and files under the file share, including the root directory.
1. Open Windows File Explorer and right click on the file/directory and select Properties.
2. Select the Security tab.
3. Select Edit.. to change permissions.
4. You can change the permissions of existing users or select Add... to grant permissions to new users.
5. In the prompt window for adding new users, enter the target username you want to grant permissions to in the Enter the object names to select box, and select Check Names to find the full UPN name of the target user.
6. Select OK.
7. In the Security tab, select all permissions you want to grant your new user.
8. Select Apply.


#### Part four: mount a file share from a domain-joined VM

```
$connectTestResult = Test-NetConnection -ComputerName qnastcshared01.file.core.windows.net -Port 445
if ($connectTestResult.TcpTestSucceeded) {
  # Mount the drive
  net use S: \\stgunique0001.file.core.windows.net\sitecoreshared01
} else {
  Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
}
```

#### Configure storage permissions for use with Profile Containers and Office Containers

There are many ways to create secure and functional storage permissions for use with Profile Containers and Office Container. Below is one configuration option that provides new-user functionality that doesn't require users to have administrative permissions.

<img width="831" alt="image" src="https://user-images.githubusercontent.com/13816859/159857419-2d309e91-04ec-492e-8789-c7ca7c1d6e71.png">


**Link to the Azure Files Script(AzFilesHybrid):**
https://github.com/Azure-Samples/azure-files-samples/releases
