### Exclude Teams and browsers Cache with redirections.xml to reduce profile container size

1 - Prepare the XML file.

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
