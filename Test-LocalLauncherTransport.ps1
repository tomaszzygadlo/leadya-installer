param([string]$NsisCompiler, [string]$PluginDirectory)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LaunchLocalLeadYa.vbs')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$installer = [IO.File]::ReadAllText((Join-Path $source 'Leadya.nsi'))
$finish = [regex]::Match($installer, '(?ms)^Function RunInstalledLocalApplication\r?\n.*?^FunctionEnd').Value
if (-not $finish -or $finish -match '(?i)wscript\.exe|\.vbs' -or
    $finish -notmatch 'ShellExecAsUser::ShellExecAsUser' -or
    $finish -notmatch 'powershell\.exe' -or $finish -notmatch '-WindowStyle Hidden' -or $finish -notmatch 'SW_HIDE') {
    throw 'LOCAL_FINISH_TRANSPORT: finishing the installer must invoke the hidden ordinary PowerShell launcher without the VBS file association'
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-launch-transport-' + [Guid]::NewGuid().ToString('N') + ' ! & ż')
try {
    $errors = $null
    $launcherTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'LaunchLocalLeadYa.ps1'), [ref]$null, [ref]$errors)
    foreach ($name in @('ConvertTo-LocalLaunchCode', 'Get-LocalJvmFailureCode', 'Enter-LocalLaunchGate', 'Invoke-LocalLaunchBootstrap', 'Write-LocalLaunchEvent', 'Invoke-LocalLaunchPreparation')) {
        $definition = $launcherTree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $definition) { throw "Missing production startup recovery function: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    $script:noticeCount = 0
    $script:waits = @()
    function Show-LocalLaunchMemoryNotice { $script:noticeCount++ }
    function Wait-LocalLaunchMemory([int]$Milliseconds) { $script:waits += $Milliseconds }
    $resourceQueries = $launcherTree.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -in @('Get-CimInstance', 'Get-WmiObject', 'Get-Counter', 'Get-LocalLaunchMemoryPressure')
    }, $true)
    if ($resourceQueries.Count) { throw 'Application startup must not query machine resources' }
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $script:startupLog = Join-Path $fixture 'startup.log'
    $script:attemptCount = 0
    Invoke-LocalLaunchPreparation -SessionAlive { $true } -Attempt {
        $script:attemptCount++
        [pscustomobject]@{ ExitCode = $(if ($script:attemptCount -lt 3) { 12 } else { 0 }); Code = $(if ($script:attemptCount -lt 3) { 'LOCAL_JAVA_MEMORY' } else { 'LOCAL_VALID' }) }
    }
    if ($script:attemptCount -ne 3 -or $script:noticeCount -ne 1 -or ($script:waits -join ',') -ne '3000,3000') {
        throw 'Startup must attempt Java immediately without checking RAM; only a real JVM allocation failure may delay retry'
    }
    $script:waits = @()
    $script:attemptCount = 0
    try {
        Invoke-LocalLaunchPreparation -SessionAlive { $true } -Attempt {
            $script:attemptCount++
            [pscustomobject]@{ ExitCode = 12; Code = 'LOCAL_PRIVATE_ACL' }
        }
        throw 'Policy failure was accepted'
    } catch { if ($_.Exception.Message -cne 'LOCAL_PRIVATE_ACL') { throw } }
    if ($script:attemptCount -ne 1 -or $script:waits.Count) { throw 'A custody refusal must never be retried as memory pressure' }
    $script:noticeCount = 0
    Invoke-LocalLaunchPreparation -SessionAlive { $true } -Attempt {
        [pscustomobject]@{ ExitCode = 0; Code = 'LOCAL_VALID' }
    }
    if ($script:waits.Count -or $script:noticeCount) { throw 'Successful Java startup must not wait or show a resource notice' }
    try {
        Invoke-LocalLaunchPreparation -SessionAlive { $false } -Attempt {
            [pscustomobject]@{ ExitCode = 12; Code = 'LOCAL_JAVA_MEMORY' }
        }
        throw 'Orphaned launch kept retrying'
    } catch { if ($_.Exception.Message -cne 'LOCAL_LAUNCH_SESSION_ENDED') { throw } }
    Write-LocalLaunchEvent 'PREPARE_FAILED' 'secret@example.test clientToken=PRIVATE'
    $log = [IO.File]::ReadAllText($script:startupLog)
    if ($log -match 'secret@|clientToken=| PRIVATE' -or $log -notmatch 'PREPARE_FAILED LOCAL_VALIDATION_FAILED') {
        throw 'Startup diagnostics must retain a safe stage/code without arbitrary validator output'
    }
    $script:startupLog = $null
    $gateName = 'Local\LeadYa.Test.' + [Guid]::NewGuid().ToString('N')
    $gate = Enter-LocalLaunchGate $gateName
    try {
        $gateResult = Join-Path $fixture 'gate.txt'
        $body = '$m=[Threading.Mutex]::new($false,''' + $gateName + '''); try{[IO.File]::WriteAllText(''' + $gateResult.Replace("'", "''") + ''',[string]$m.WaitOne(0))}finally{$m.Dispose()}'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
        $gateChild = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded) -WindowStyle Hidden -Wait -PassThru
        if ($gateChild.ExitCode -ne 0 -or [IO.File]::ReadAllText($gateResult) -cne 'False') { throw 'Concurrent pending launch was allowed to duplicate its notification and process' }
    } finally { $gate.ReleaseMutex(); $gate.Dispose() }
    $validatorTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'ValidateLocalInstall.ps1'), [ref]$null, [ref]$errors)
    $validatorClassifier = $validatorTree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-LocalJvmFailureCode' }, $true)
    $classify = [scriptblock]::Create("param([string]`$Value)`n" + $validatorClassifier.Extent.Text + "`nGet-LocalJvmFailureCode `$Value")
    foreach ($sample in @('Could not reserve enough space', 'Unrecognized VM option', 'OutOfMemoryError', 'LOCAL_STARTUP_POLICY_REFUSED')) {
        if ((& $classify $sample) -cne (Get-LocalJvmFailureCode $sample)) { throw 'Standalone JVM classifiers disagree' }
    }
    foreach ($name in @('New-LocalJavaStartInfo', 'Invoke-JavaProbe')) {
        $definition = $validatorTree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $definition) { throw "Missing production Java boundary: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    $package = $fixture
    $elevated = $false
    $JavaExecutable = Join-Path $PSHOME 'powershell.exe'
    # Substitute only Java's argv prefix. Native process creation, concurrent pipes, timeout and classification execute unchanged.
    $startInfoFunction = (Get-Command New-LocalJavaStartInfo).ScriptBlock.ToString().Replace("'-Xms16m -Xmx128m -XX:-UsePerfData ' +", "'' +")
    Set-Item Function:\New-LocalJavaStartInfo ([scriptblock]::Create($startInfoFunction))
    foreach ($case in @(
        @{ Text='Could not reserve enough space for object heap'; Code='LOCAL_JAVA_MEMORY' },
        @{ Text='Native memory allocation (malloc) failed to allocate 512 bytes'; Code='LOCAL_JAVA_MEMORY' },
        @{ Text='LOCAL_STARTUP_POLICY_REFUSED'; Code='LOCAL_JAVA_FAILED' },
        @{ Text='Unrecognized VM option'; Code='LOCAL_JAVA_FAILED' }
    )) {
        $body = '[Console]::Error.WriteLine(''' + $case.Text + '''); exit 12'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
        try {
            Invoke-JavaProbe ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded) 12000
            throw 'Failed JVM was accepted'
        } catch { if ($_.Exception.Message -cne $case.Code) { throw } }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('[Console]::Out.Write(''x'' * 70000); [Console]::Error.Write(''y'' * 70000); exit 0'))
    Invoke-JavaProbe ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded) 12000
    foreach ($streamName in @('Out', 'Error')) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('[Console]::' + $streamName + '.WriteLine(''Could not reserve enough space for object heap''); exit 1'))
        $info = New-LocalJavaStartInfo $JavaExecutable ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded) $fixture
        $failedStart = Invoke-LocalLaunchBootstrap $info
        if ($failedStart.Code -cne 'LOCAL_JAVA_MEMORY') { throw 'Actual bootstrap OOM must be detected on both native output streams' }
    }
    $java = Join-Path $env:ProgramFiles 'Java\jdk-17.0.9+9-jre\bin\java.exe'
    $compiler = Get-Command javac.exe -ErrorAction SilentlyContinue
    if ([IO.File]::Exists($java) -and $compiler) {
        $info = New-LocalJavaStartInfo $java '-Xmx999999g -version' $fixture
        $failedStart = Invoke-LocalLaunchBootstrap $info
        if ($failedStart.Code -cne 'LOCAL_JAVA_MEMORY') { throw 'Real pinned JRE heap reservation failure must be retriable' }
        $lateSource = Join-Path $fixture 'LateOutput.java'
        [IO.File]::WriteAllText($lateSource, 'import java.nio.file.*; public class LateOutput { public static void main(String[] a) throws Exception { Thread.sleep(3600); System.out.println("late stdout"); System.err.println("late stderr"); Path result=Path.of(a[0]); Path pending=Path.of(a[0]+".pending"); Files.writeString(pending, "alive"); Files.move(pending,result,StandardCopyOption.ATOMIC_MOVE); } }')
        $compile = New-Object Diagnostics.Process
        $compile.StartInfo = New-LocalJavaStartInfo $compiler.Source ('-J-Xms16m -J-Xmx64m "' + $lateSource + '"') $fixture
        try {
            [void]$compile.Start()
            if (-not $compile.WaitForExit(15000) -or $compile.ExitCode -ne 0) { throw 'Real JVM stream handoff fixture did not compile' }
        } finally { if (-not $compile.HasExited) { $compile.Kill(); $compile.WaitForExit() }; $compile.Dispose() }
        $lateResult = Join-Path $fixture 'late-result.txt'
        $info = New-LocalJavaStartInfo $java ('-Xms16m -Xmx64m -cp "' + $fixture + '" LateOutput "' + $lateResult + '"') $fixture
        $aliveStart = Invoke-LocalLaunchBootstrap $info
        if ($aliveStart.State -cne 'START_REQUESTED') { throw 'Live bootstrap was not handed off' }
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while (-not [IO.File]::Exists($lateResult) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        if (-not [IO.File]::Exists($lateResult) -or [IO.File]::ReadAllText($lateResult) -cne 'alive') { throw 'Closing early JVM diagnostic pipes must preserve the live JVM and later stdout/stderr writes' }
        Write-Output 'PASS: real pinned JRE allocation failure, bounded early capture and surviving late stdout/stderr writes'
    } else { Write-Output 'SKIP: pinned JRE and javac required for real Java stream handoff scenario' }
    Write-Output 'PASS: immediate startup without resource queries, 3s actual OOM retry, policy refusal, session end, safe log and real concurrent JVM pipes'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'LaunchLocalLeadYa.vbs') -Destination $fixture
    [IO.File]::WriteAllText((Join-Path $fixture 'LaunchLocalLeadYa.ps1'), 'param([string]$RequestedVersion); [IO.File]::WriteAllText((Join-Path $PSScriptRoot "result.txt"), ("ok:"+$RequestedVersion))')
    foreach ($version in @('', '0.11.38.167')) {
        $arguments = '//B //Nologo "' + (Join-Path $fixture 'LaunchLocalLeadYa.vbs') + '"'
        if ($version) { $arguments += ' ' + $version }
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw 'Windowless script transport failed' }
        $result = Join-Path $fixture 'result.txt'
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        while (-not [IO.File]::Exists($result) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (-not [IO.File]::Exists($result) -or [IO.File]::ReadAllText($result) -cne ('ok:' + $version)) { throw 'Launcher lost its literal path or requested version' }
        [IO.File]::Delete($result)
    }
    $parseErrors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'LaunchLocalLeadYa.ps1'), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Launcher syntax is invalid' }
    $linksFunction = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-PersonalLaunchLinks' }, $true)
    Invoke-Expression $linksFunction.Extent.Text
    $desktop = Join-Path $fixture 'Desktop.lnk'
    $startup = Join-Path $fixture 'Startup.lnk'
    $menu = Join-Path $fixture 'Menu.lnk'
    $locked = [IO.File]::Open($desktop, 'CreateNew', 'ReadWrite', 'None')
    try {
        if (-not (Update-PersonalLaunchLinks $fixture @($desktop, $startup, $menu) $startup)) { throw 'Blocked desktop prevented autostart' }
        if (-not [IO.File]::Exists($menu)) { throw 'Blocked desktop prevented Start menu refresh' }
    } finally { $locked.Dispose() }
    $locked = [IO.File]::Open($startup, 'Open', 'ReadWrite', 'None')
    try {
        if (Update-PersonalLaunchLinks $fixture @($startup) $startup) { throw 'Blocked startup must preserve legacy registration' }
    } finally { $locked.Dispose() }
    Write-Output 'PASS: real WScript to hidden PowerShell, literal Unicode path, normal and versioned launch'
    # Compile and execute the actual finish callback, with an inert adjacent launcher.
    # This crosses the real NSIS plugin/ShellExecute boundary; no LeadYa profile or session is touched.
    $compiler = if ($NsisCompiler) { $NsisCompiler } else { (Get-Command makensis -ErrorAction Stop).Source }
    $plugins = if ($PluginDirectory) { $PluginDirectory } else { Join-Path $source 'plugins' }
    if (-not (Test-Path -LiteralPath (Join-Path $plugins 'ShellExecAsUser.dll') -PathType Leaf)) { throw 'The actual finish plugin is required for this test' }
    $probeExe = Join-Path $fixture 'finish-probe.exe'
    $probeSource = @'
Unicode true
Name "LeadYa finish transport fixture"
RequestExecutionLevel user
SilentInstall silent
OutFile "finish-probe.exe"
!addplugindir "@PLUGINS@"
Var LocalTrustedHome
@FINISH@
Section
  StrCpy $LocalTrustedHome "$EXEDIR"
  Call RunInstalledLocalApplication
SectionEnd
'@
    $probeSource = $probeSource.Replace('@PLUGINS@', $plugins).Replace('@FINISH@', $finish)
    [IO.File]::WriteAllText((Join-Path $fixture 'finish-probe.nsi'), $probeSource, [Text.UTF8Encoding]::new($true))
    $stub = @'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class FinishWindow { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window); }'
$elevated = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$data = [pscustomobject]@{ folder=$PSScriptRoot; elevated=$elevated; consoleVisible=[FinishWindow]::IsWindowVisible([FinishWindow]::GetConsoleWindow()); pid=$PID }
$output = Join-Path $PSScriptRoot 'finish-result.json'
[IO.File]::WriteAllText(($output+'.tmp'), ($data | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
[IO.File]::Move(($output+'.tmp'), $output)
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'LaunchLocalLeadYa.ps1'), $stub, [Text.UTF8Encoding]::new($true))
    Push-Location -LiteralPath $fixture
    try { & $compiler /V2 (Join-Path $fixture 'finish-probe.nsi'); if ($LASTEXITCODE -ne 0) { throw 'Actual NSIS finish fixture did not compile' } }
    finally { Pop-Location }
    $probe = Start-Process -FilePath $probeExe -ArgumentList '/S' -WindowStyle Hidden -PassThru
    if (-not $probe.WaitForExit(15000)) { throw 'Actual NSIS finish fixture did not exit' }
    $result = Join-Path $fixture 'finish-result.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not [IO.File]::Exists($result) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not [IO.File]::Exists($result)) { throw 'Actual finish callback did not start its ordinary hidden launcher' }
    $actual = [IO.File]::ReadAllText($result) | ConvertFrom-Json
    if ($actual.folder -cne $fixture -or $actual.elevated -or $actual.consoleVisible) { throw 'Finish callback lost the literal path, ordinary token, or hidden console' }
    $child = Get-Process -Id $actual.pid -ErrorAction SilentlyContinue
    if ($child -and -not $child.WaitForExit(10000)) { throw 'Inert finish launcher did not exit' }
    Write-Output 'PASS: actual compiled NSIS finish callback, ordinary hidden PowerShell, Unicode path, no VBS dependency'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-launch-transport-[a-f0-9]{32} ! & ż$' -and [IO.Directory]::Exists($resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
