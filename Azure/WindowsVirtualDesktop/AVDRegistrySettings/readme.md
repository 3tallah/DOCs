### Download Registry Files Samples and update them based on your Environment.

WVD FSLogix Profile Configuration > [FSLogix.reg](https://github.com/3tallah/DOCs/blob/master/Azure/WindowsVirtualDesktop/AVDRegistrySettings/FSLogix.reg)

WVD OneDrive SSO GPO > [OneDrive.reg](https://github.com/3tallah/DOCs/blob/master/Azure/WindowsVirtualDesktop/AVDRegistrySettings/OneDrive.reg)

WVD Enabling session shadowing > [Terminal Server.reg](https://github.com/3tallah/DOCs/blob/master/Azure/WindowsVirtualDesktop/AVDRegistrySettings/Terminal%20Server.reg)

WVD Antivirus exclusions > [Windows Defender.reg](https://github.com/3tallah/DOCs/blob/master/Azure/WindowsVirtualDesktop/AVDRegistrySettings/Windows%20Defender.reg)

### Exclude Teams and browsers Cache with redirections.xml to reduce profile container size

1 - Prepare the XML file. [ReadySample](https://github.com/3tallah/DOCs/blob/master/Azure/WindowsVirtualDesktop/AVDRegistrySettings/redirections.xml)

2 - Save the XML under this Location

F:\windows\SYSVOL\sysvol\domain\scripts\WVD\redirections.xml

3 - Configure the GPO:

Computer Configuration\Policies\Administrative Templates\FSLogix\Profile Containers\Advanced\Provide RedirXML file to customize redirections
Setting: Enabled
Path: Provide the only the folder path where the file is located!


### WVD Antivirus exclusions

#### File type exclusions:

- *.vhd,*.vhdx,*.avhd,*.avhdx,*.vsv,*.iso,*.rct,*.vmcx,*.vmrs
Folder exclusions: Exclude files:

- %ProgramFiles%\FSLogix\Apps\frxdrv.sys
- %ProgramFiles%\FSLogix\Apps\frxdrvvt.sys
- %ProgramFiles%\FSLogix\Apps\frxccd.sys
- %TEMP%.VHD
- %TEMP%.VHDX
- %Windir%\TEMP*.VHD
- %Windir%\TEMP*.VHDX
- \storageaccount.file.core.windows.net\share**.VHD
- \storageaccount.file.core.windows.net\share**.VHDX
Exclude processes:

- %ProgramFiles%\FSLogix\Apps\frxccd.exe
- %ProgramFiles%\FSLogix\Apps\frxccds.exe
- %ProgramFiles%\FSLogix\Apps\frxsvc.exe
- %Programdata%\FSLogix\Cache
- %Programdata%\FSLogix\Proxy
