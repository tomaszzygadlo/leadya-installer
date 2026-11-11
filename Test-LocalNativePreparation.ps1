$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-native-retry-' + [Guid]::NewGuid().ToString('N') + ' ! & ż')
$sourceDirectory = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LaunchLocalLeadYa.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$source = Join-Path $sourceDirectory 'LaunchLocalLeadYa.ps1'
$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Invalid production launcher syntax' }
foreach ($name in @('ConvertTo-LocalLaunchCode', 'Get-LocalJvmFailureCode', 'Write-LocalLaunchEvent', 'Invoke-LocalLaunchBootstrap', 'Invoke-LocalLaunchPreparation',
    'Invoke-LocalProfileStep', 'Get-LocalLaunchFailureMessage')) {
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
# Another hidden process holds the marker like a scanner, for the given time only.
function Start-MarkerHolder([string]$Marker, [int]$Milliseconds) {
    $ready = $Marker + '.held'
    if ([IO.File]::Exists($ready)) { [IO.File]::Delete($ready) }
    $body = '$h=[IO.File]::Open(''' + $Marker.Replace("'", "''") + ''',''Open'',''Read'',''None''); [IO.File]::WriteAllText(''' + $ready.Replace("'", "''") + ''',''1''); Start-Sleep -Milliseconds ' + $Milliseconds + '; $h.Dispose()'
    $holder = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body)))
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not [IO.File]::Exists($ready)) {
        if ([DateTime]::UtcNow -gt $deadline -or $holder.HasExited) { throw 'The marker holder did not start' }
        Start-Sleep -Milliseconds 20
    }
    return $holder
}
# The profile step as the validator answers it: a read error of the marker is LOCAL_VALIDATION_FAILED.
function Read-HeldMarker([string]$Marker) {
    $script:profileAttempts++
    try { [void][IO.File]::ReadAllLines($Marker); return [pscustomobject]@{ ExitCode=0; Output='LOCAL_VALID' } }
    catch { return [pscustomobject]@{ ExitCode=12; Output='LOCAL_VALIDATION_FAILED' } }
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
    # A marker held for less than the retry window: the profile step waits about a second and then succeeds.
    $marker = Join-Path $fixture 'leadya-local-install.txt'
    [IO.File]::WriteAllText($marker, '[TEST] marker')
    [IO.File]::WriteAllText($script:startupLog, '')
    $script:profileAttempts = 0
    $holder = Start-MarkerHolder $marker 1500
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-LocalProfileStep -Phase PROFILE -Attempt { Read-HeldMarker $marker }
        $watch.Stop()
    } finally { $holder.WaitForExit(); $holder.Dispose() }
    if ($result.ExitCode -ne 0 -or $script:profileAttempts -lt 2 -or $script:profileAttempts -gt 3) { throw "A briefly held marker must pass on a retry: $($script:profileAttempts) attempts" }
    if ($watch.ElapsedMilliseconds -lt 900) { throw 'The retry must wait about a second' }
    if ([IO.File]::ReadAllText($script:startupLog) -notmatch 'PROFILE_RETRY LOCAL_VALIDATION_FAILED') { throw 'A retry must be visible in the startup log' }
    # Held longer than the window: three attempts, then the read error is final.
    $script:profileAttempts = 0
    $script:pauses = 0
    $holder = Start-MarkerHolder $marker 3000
    try {
        $result = Invoke-LocalProfileStep -Phase PREPARE -Pause { $script:pauses++ } -Attempt { Read-HeldMarker $marker }
    } finally { $holder.WaitForExit(); $holder.Dispose() }
    if ($result.ExitCode -eq 0 -or $result.Output -cne 'LOCAL_VALIDATION_FAILED' -or $script:profileAttempts -ne 3 -or $script:pauses -ne 2) {
        throw "A marker held for long must fail after three attempts: $($script:profileAttempts) attempts, $($script:pauses) pauses"
    }
    # A fixed refusal is final at once, as is success.
    $script:profileAttempts = 0
    $script:pauses = 0
    $result = Invoke-LocalProfileStep -Phase PROFILE -Pause { $script:pauses++ } -Attempt { $script:profileAttempts++; [pscustomobject]@{ ExitCode=12; Output='LOCAL_MARKER_MISMATCH' } }
    if ($result.Output -cne 'LOCAL_MARKER_MISMATCH' -or $script:profileAttempts -ne 1 -or $script:pauses) { throw 'A fixed refusal must not be retried' }
    # The person reads plain words in Polish or English; the code stands on its own line for technical support.
    # Only a failure that passes by itself asks to try again; any other asks to install again or to contact support.
    $failed = "Nie uda$([char]0x0142)o si$([char]0x0119) uruchomi$([char]0x0107) LeadYa."
    $retryPolish = "$failed Spr$([char]0x00F3)buj ponownie za chwil$([char]0x0119)."
    $reinstallPolish = "$failed Zainstaluj LeadYa ponownie. Je$([char]0x015B)li to nie pomo$([char]0x017C)e, skontaktuj si$([char]0x0119) z pomoc$([char]0x0105) techniczn$([char]0x0105)."
    $retryEnglish = 'LeadYa could not start. Please try again in a moment.'
    $reinstallEnglish = 'LeadYa could not start. Install LeadYa again. If that does not help, contact technical support.'
    foreach ($case in @(
        @('PROFILE', 'LOCAL_VALIDATION_FAILED', 'pl', $retryPolish, 'Kod dla pomocy technicznej:'),
        @('PREPARE', 'LOCAL_JAVA_MEMORY', 'pl', $retryPolish, 'Kod dla pomocy technicznej:'),
        @('PREPARE', 'LOCAL_JAVA_FAILED', 'pl', $reinstallPolish, 'Kod dla pomocy technicznej:'),
        @('PACKAGE', 'LOCAL_PACKAGE_MISSING', 'pl', $reinstallPolish, 'Kod dla pomocy technicznej:'),
        @('PROFILE', 'LOCAL_VALIDATION_FAILED', 'en', $retryEnglish, 'Code for technical support:'),
        @('BOOTSTRAP', 'LOCAL_JAVA_MEMORY', 'de', $retryEnglish, 'Code for technical support:'),
        @('PREPARE', 'LOCAL_JAVA_FAILED', '', $reinstallEnglish, 'Code for technical support:'),
        @('PROFILE', 'LOCAL_MARKER_MISMATCH', 'en', $reinstallEnglish, 'Code for technical support:'))) {
        $message = Get-LocalLaunchFailureMessage $case[0] $case[1] $case[2]
        $expected = $case[3] + "`n`n" + $case[4] + "`n" + $case[0] + ': ' + $case[1]
        if ($message -cne $expected) { throw "Failure message for $($case[1]) in '$($case[2])' changed: $message" }
    }
    $elevated = Get-LocalLaunchFailureMessage 'START' 'LOCAL_ELEVATED_RUNTIME' 'pl'
    if ($elevated -notmatch 'nie jako administrator\.' -or -not $elevated.EndsWith("Kod dla pomocy technicznej:`nSTART: LOCAL_ELEVATED_RUNTIME")) { throw "Elevated message changed: $elevated" }
    $elevated = Get-LocalLaunchFailureMessage 'START' 'LOCAL_ELEVATED_RUNTIME' 'en'
    if ($elevated -notmatch 'not as administrator\.' -or -not $elevated.EndsWith("Code for technical support:`nSTART: LOCAL_ELEVATED_RUNTIME")) { throw "Elevated message changed: $elevated" }
    # Production wiring: both profile calls of the validator go through the retry, and the dialog follows the UI language.
    foreach ($mode in @('Runtime', 'Prepare')) {
        $call = $tree.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Ampersand' -and
            $node.Extent.Text -match ('-Mode ' + $mode + ' ')
        }, $true)
        if (-not $call) { throw "Missing $mode call of the validator" }
        $ancestor = $call.Parent
        while ($ancestor -and -not ($ancestor -is [Management.Automation.Language.CommandAst] -and $ancestor.GetCommandName() -eq 'Invoke-LocalProfileStep')) { $ancestor = $ancestor.Parent }
        if (-not $ancestor) { throw "The $mode call of the validator must be inside the profile retry" }
    }
    $mainTry = $tree.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
    $failure = $mainTry.CatchClauses[0].Body.Extent.Text
    if ($failure.IndexOf('(Get-UICulture).TwoLetterISOLanguageName') -lt 0 -or $failure.IndexOf('Get-LocalLaunchFailureMessage $stage $code $language') -lt 0 -or
        $failure.IndexOf('if (-not $NoDialog') -lt 0) { throw 'The failure dialog must use the plain message in the UI language and keep -NoDialog' }
    Write-Output 'PASS: actual hidden stderr OOM retry, Base64 stdout, Win32 memory retry, owner end, permanent refusal, late output, bounded pipes, timeout child cleanup, production wiring, held marker retry, plain failure message by code'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
