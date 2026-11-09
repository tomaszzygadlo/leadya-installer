param([Parameter(Mandatory)][string]$Executable,
      [string[]]$Arguments=@(),
      [Parameter(Mandatory)][string]$WorkingDirectory,
      [Parameter(Mandatory)][string]$Log,
      [int]$Seconds=300,
      [string]$CleanupMarker,
      [switch]$BootstrapSource)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'PrivateUnitProcess.cs')
$safe=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$names=@('SystemRoot','WINDIR','COMSPEC','PATH','PATHEXT','TEMP','TMP','USERPROFILE','HOMEDRIVE','HOMEPATH','LOCALAPPDATA','APPDATA','PROGRAMDATA','ProgramFiles','ProgramFiles(x86)','ProgramW6432','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS','JAVA_HOME','JAVA_HOME_17_X64','MAVEN_HOME','M2_HOME','PSModulePath','RUNNER_TEMP','LEADYA_SOURCE_COMMIT','LEADYA_SOURCE_TREE','LEADYA_ARCHIVE_SHA256','DEVUNIT_RED_TREE','DEVUNIT_GREEN_TREE','DEVUNIT_ZIP_SHA256','DEVUNIT_SOURCE_ROOT','DEVUNIT_RESULT_ROOT','DEVUNIT_BOOTSTRAP_ROOT')
if($BootstrapSource){$names+=0..88 | ForEach-Object {'LEADYA_SOURCE_{0:D3}' -f $_}}
foreach($name in $names){$value=[Environment]::GetEnvironmentVariable($name);if($null -ne $value){$safe[$name]=$value}}
$safe['GIT_NO_LAZY_FETCH']='1';$safe['GIT_TERMINAL_PROMPT']='0';$safe['GIT_CONFIG_NOSYSTEM']='1';$safe['GIT_CONFIG_GLOBAL']='NUL'
if($CleanupMarker -and (Test-Path -LiteralPath $CleanupMarker)){Remove-Item -LiteralPath $CleanupMarker}
try{
 $code=[PrivateUnitProcess]::Run($Executable,$Arguments,$WorkingDirectory,$Log,$Seconds,33554432,$safe)
}finally{
 if($CleanupMarker -and [PrivateUnitProcess]::CleanupVerified){[IO.File]::WriteAllText($CleanupMarker,'owned_job_active_processes=0')}
}
exit $code
