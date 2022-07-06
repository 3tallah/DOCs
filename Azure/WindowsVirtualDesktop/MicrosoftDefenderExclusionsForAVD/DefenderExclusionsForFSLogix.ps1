 # Defender Exclusions for FSLogix
  $Cloudcache = $false             # Set for true if using cloud cache
  $StorageAcct = "<Storage Account Name>"     # Storage Account Name

  $filelist = `
  "%ProgramFiles%\FSLogix\Apps\frxdrv.sys", `
  "%ProgramFiles%\FSLogix\Apps\frxdrvvt.sys", `
  "%ProgramFiles%\FSLogix\Apps\frxccd.sys", `
  "%TEMP%\*.VHD", `
  "%TEMP%\*.VHDX", `
  "%Windir%\TEMP\*.VHD", `
  "%Windir%\TEMP\*.VHDX", `
  "\\$Storageacct.file.core.windows.net\share\*.VHD", `
  "\\$Storageacct.file.core.windows.net\share\*.VHDX"

  $processlist = `
  "%ProgramFiles%\FSLogix\Apps\frxccd.exe", `
  "%ProgramFiles%\FSLogix\Apps\frxccds.exe", `
  "%ProgramFiles%\FSLogix\Apps\frxsvc.exe"

  Foreach($item in $filelist){
      Add-MpPreference -ExclusionPath $item}
  Foreach($item in $processlist){
      Add-MpPreference -ExclusionProcess $item}

  If ($Cloudcache){
      Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Cache\*.VHD"
      Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Cache\*.VHDX"
      Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Proxy\*.VHD"
      Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Proxy\*.VHDX"} 
