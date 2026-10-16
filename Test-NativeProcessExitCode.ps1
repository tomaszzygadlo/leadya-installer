# Exercise the real Windows process API used by the release scanner. No installer runs.
$ErrorActionPreference = 'Stop'
foreach ($expected in @(0, 2)) {
    $outputFile = [IO.Path]::GetTempFileName()
    $errorFile = [IO.Path]::GetTempFileName()
    $process = $null
    try {
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/d', '/c', 'exit', $expected) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile
        $null = $process.Handle
        if (-not $process.WaitForExit(5000)) {
            $process.Kill(); $process.WaitForExit()
            throw 'Native exit-code probe timed out'
        }
        if ($null -eq $process.ExitCode -or $process.ExitCode -ne $expected) { throw "Expected native exit $expected, observed '$($process.ExitCode)'" }
        Write-Output "PowerShell $($PSVersionTable.PSVersion): native exit $expected PASS"
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $outputFile, $errorFile -Force -ErrorAction SilentlyContinue
    }
}
