$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-native-retry-' + [Guid]::NewGuid().ToString('N') + ' ! & ż')
$sourceDirectory = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LaunchLocalLeadYa.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$source = Join-Path $sourceDirectory 'LaunchLocalLeadYa.ps1'
$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Invalid production launcher syntax' }
foreach ($name in @('ConvertTo-LocalLaunchCode', 'Get-LocalJvmFailureCode', 'Write-LocalLaunchEvent', 'Invoke-LocalLaunchBootstrap', 'Invoke-LocalLaunchPreparation')) {
    $definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing production function: $name" }
    Invoke-Expression $definition.Extent.Text
}
function New-TestStart([string]$Body) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Body))
    $info.WorkingDirectory = $fixture
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    return $info
}
function Show-LocalLaunchMemoryNotice { $script:notices++ }
function Wait-LocalLaunchMemory([int]$Milliseconds) {
    $script:waits++
    if ($script:endDuringWait) { $script:ownerAlive = $false }
}
function Reset-TestState {
    $script:notices = 0; $script:waits = 0; $script:ownerAlive = $true; $script:endDuringWait = $false
}
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $script:startupLog = Join-Path $fixture 'startup.txt'
    $counter = Join-Path $fixture 'attempts.txt'
    $expected = Join-Path $fixture '.leadya-native\fixture\bin\LeadYa Checking Program.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected))
    $body = '$p=''' + $counter.Replace("'", "''") + '''; $n=if(Test-Path -LiteralPath $p){[int][IO.File]::ReadAllText($p)}else{0}; [IO.File]::WriteAllText($p,[string]($n+1)); if($n -eq 0){[Console]::Error.WriteLine(''Could not reserve enough space for object heap; clientToken=PRIVATE''); exit 12}; [Console]::Out.Write(''' + $encoded + '''); exit 0'
    $info = New-TestStart $body
    Reset-TestState
    $result = Invoke-LocalLaunchPreparation -SessionAlive { $script:ownerAlive } -Attempt {
        Invoke-LocalLaunchBootstrap $info -NativePreparation
    }
    if ($result.Output -cne $encoded -or [IO.File]::ReadAllText($counter) -cne '2' -or $script:waits -ne 1 -or $script:notices -ne 1) {
        throw 'Native preparation must retry actual stderr allocation failure and return only the successful Base64 stdout'
    }
    [IO.File]::WriteAllText($counter, '0')
    Reset-TestState
    $script:endDuringWait = $true
    try {
        Invoke-LocalLaunchPreparation -SessionAlive { $script:ownerAlive } -Attempt { Invoke-LocalLaunchBootstrap $info -NativePreparation } | Out-Null
        throw 'Owner ended but native preparation continued'
    } catch { if ($_.Exception.Message -cne 'LOCAL_LAUNCH_SESSION_ENDED') { throw } }
    if ([IO.File]::ReadAllText($counter) -cne '1' -or $script:waits -ne 1) { throw 'Ended owner must prevent a second child' }
    Reset-TestState
    $denied = New-TestStart '[Console]::Error.WriteLine("LOCAL_PRIVATE_ACL clientToken=PRIVATE"); exit 12'
    try {
        Invoke-LocalLaunchPreparation -SessionAlive { $true } -Attempt { Invoke-LocalLaunchBootstrap $denied -NativePreparation } | Out-Null
        throw 'Permanent preparation failure was accepted'
    } catch { if ($_.Exception.Message -cne 'LOCAL_JAVA_FAILED') { throw } }
    if ($script:waits -or $script:notices) { throw 'Permanent failure must not wait or retry' }
    Reset-TestState
    $script:attempts = 0
    $success = New-TestStart ('[Console]::Out.Write(''' + $encoded + '''); exit 0')
    $result = Invoke-LocalLaunchPreparation -SessionAlive { $true } -Attempt {
        $script:attempts++
        if ($script:attempts -eq 1) { throw [ComponentModel.Win32Exception]::new(1455) }
        Invoke-LocalLaunchBootstrap $success -NativePreparation
    }
    if ($result.Output -cne $encoded -or $script:attempts -ne 2 -or $script:waits -ne 1) { throw 'Native Win32 allocation failure must use the same retry classification' }
    $late = New-TestStart ('Start-Sleep -Milliseconds 3600; [Console]::Out.Write(''' + $encoded + '''); exit 0')
    $result = Invoke-LocalLaunchBootstrap $late -NativePreparation
    if ($result.Output -cne $encoded) { throw 'Preparation must await its output beyond the bootstrap handoff window' }
    $pipes = New-TestStart '[Console]::Out.Write("x" * 70000); [Console]::Error.Write("Could not reserve enough space " + ("y" * 70000)); exit 12'
    $result = Invoke-LocalLaunchBootstrap $pipes -NativePreparation
    if ($result.Code -cne 'LOCAL_JAVA_MEMORY') { throw 'Both full pipes must be drained without deadlock' }
    $pidFile = Join-Path $fixture 'child-pid.txt'
    $slow = New-TestStart ('[IO.File]::WriteAllText(''' + $pidFile.Replace("'", "''") + ''',[string]$PID); Start-Sleep -Seconds 30')
    $result = Invoke-LocalLaunchBootstrap $slow -NativePreparation -PreparationTimeoutMilliseconds 5000
    if ($result.Code -cne 'LOCAL_JAVA_TIMEOUT' -or -not [IO.File]::Exists($pidFile)) { throw 'Preparation timeout was not exercised' }
    if (Get-Process -Id ([int][IO.File]::ReadAllText($pidFile)) -ErrorAction SilentlyContinue) { throw 'Timed out preparation child survived' }
    if ([IO.File]::ReadAllText($script:startupLog) -match 'clientToken|PRIVATE') { throw 'Captured diagnostics leaked into the startup log' }
    $nativeCalls = @($tree.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-LocalLaunchBootstrap' -and
        @($node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'NativePreparation' }).Count -eq 1
    }, $true))
    if ($nativeCalls.Count -ne 1) { throw 'Main must use exactly one native preparation boundary' }
    $ancestor = $nativeCalls[0].Parent
    while ($ancestor -and -not ($ancestor -is [Management.Automation.Language.CommandAst] -and $ancestor.GetCommandName() -eq 'Invoke-LocalLaunchPreparation')) { $ancestor = $ancestor.Parent }
    if (-not $ancestor) { throw 'Main native preparation must be inside the owner-bound retry' }
    Write-Output 'PASS: actual hidden stderr OOM retry, Base64 stdout, Win32 memory retry, owner end, permanent refusal, late output, bounded pipes, timeout child cleanup and production wiring'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
