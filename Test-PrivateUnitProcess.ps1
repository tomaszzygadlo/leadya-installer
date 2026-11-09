param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'PrivateUnitProcess.cs')
$root=Join-Path ([IO.Path]::GetTempPath()) ('private-unit-native-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$safe=[Collections.Generic.Dictionary[string,string]]::new()
foreach($name in @('SystemRoot','COMSPEC','PATH','TEMP','TMP')){$safe[$name]=[Environment]::GetEnvironmentVariable($name)}
$checks=@()
try{
 $code=[PrivateUnitProcess]::Run($env:COMSPEC,@('/d','/s','/c','exit 7'),$root,(Join-Path $root 'exit.log'),10,1024,$safe)
 if($code -ne 7 -or -not [PrivateUnitProcess]::CleanupVerified){throw "Native exit/cleanup lost: code=$code cleanup=$([PrivateUnitProcess]::CleanupVerified)"}
 $checks+='exit-code-and-owned-cleanup'
 try{[PrivateUnitProcess]::Run($env:COMSPEC,@('/d','/s','/c','ping -n 30 127.0.0.1 > NUL'),$root,(Join-Path $root 'timeout.log'),1,1024,$safe);throw 'Timeout failed'}catch{
  if($_.Exception.ToString() -notmatch 'timed out' -or -not [PrivateUnitProcess]::CleanupVerified){throw}
 }
 $checks+='timeout-stops-owned-descendants'
 try{[PrivateUnitProcess]::Run($env:COMSPEC,@('/d','/s','/c','for /L %i in (1,1,10000) do @echo bounded-private-output'),$root,(Join-Path $root 'cap.log'),10,1024,$safe);throw 'Log cap failed'}catch{
  if($_.Exception.ToString() -notmatch 'log limit' -or -not [PrivateUnitProcess]::CleanupVerified){throw}
 }
 $checks+='log-cap-stops-owned-descendants'
 $env:PRIVATE_UNIT_SENTINEL='must-not-reach-child'
 $powershell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
 $script='if($env:PRIVATE_UNIT_SENTINEL){exit 3};exit 0'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
 $code=[PrivateUnitProcess]::Run($powershell,@('-NoProfile','-WindowStyle','Hidden','-EncodedCommand',$encoded),$root,(Join-Path $root 'env.log'),20,1024,$safe)
 if($code -ne 0 -or -not [PrivateUnitProcess]::CleanupVerified){throw 'Secret reached child'}
 Remove-Item Env:PRIVATE_UNIT_SENTINEL
 $checks+='sentinel-secret-absent-in-child'
 $pidPath=Join-Path $root 'owned-child-pid.txt'
 $script='$p=Start-Process -FilePath $env:COMSPEC -ArgumentList @(''/d'',''/s'',''/c'',''ping -n 30 127.0.0.1 > NUL'') -WindowStyle Hidden -PassThru;[IO.File]::WriteAllText('''+$pidPath+''',[string]$p.Id)'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
 $code=[PrivateUnitProcess]::Run($powershell,@('-NoProfile','-WindowStyle','Hidden','-EncodedCommand',$encoded),$root,(Join-Path $root 'child.log'),20,1024,$safe)
 if($code -ne 0 -or -not [PrivateUnitProcess]::CleanupVerified){throw 'Descendant cleanup failed'}
 $childId=[int][IO.File]::ReadAllText($pidPath)
 if(Get-Process -Id $childId -ErrorAction SilentlyContinue){throw 'Owned descendant survived parent'}
 $checks+='parent-exits-first-descendant-stopped'
 @{status='PASS';checks=$checks} | ConvertTo-Json | Set-Content -LiteralPath $Output
}finally{
 # Only this test's new disposable directory, after its native jobs have stopped.
 if([PrivateUnitProcess]::CleanupVerified -and [IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}
}
