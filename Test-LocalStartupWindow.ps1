param([string]$Launcher)
$ErrorActionPreference = 'Stop'
if (-not $Launcher) {
    $source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LaunchLocalLeadYa.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
    $Launcher = Join-Path $source 'LaunchLocalLeadYa.ps1'
}
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Launcher syntax is invalid' }
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-LocalClientWindow'
}, $true)
if (-not $definition) { throw 'Production window wait is missing' }
Invoke-Expression $definition.Extent.Text

# Exercise the real polling function without launching an application or touching a profile.
function Get-Process {
    param($Name)
    if ($script:fixtureName -in $Name) {
        $process = [pscustomobject]@{
            ProcessName = $script:fixtureName
            Path = $script:fixturePath
            StartTime = $script:fixtureTime
            MainWindowHandle = $script:fixtureWindow
        }
        $process | Add-Member ScriptMethod Dispose { }
        return $process
    }
}
function Assert-WindowState([string]$Expected, [string]$Scenario, [bool]$Closed = $false) {
    $actual = Wait-LocalClientWindow @{ Closed=$Closed } 'C:\TestJava\bin' $script:clicked 10 'C:\TestRuntime'
    if ($actual -cne $Expected) { throw "$Scenario : expected $Expected, got $actual" }
    Write-Output "PASS: $Scenario"
}
$script:clicked = [DateTime]::Now.AddSeconds(-1)
$script:fixtureTime = [DateTime]::Now
$script:fixtureWindow = [IntPtr]123
foreach ($role in @('LeadYa Checking Program', 'LeadYa')) {
    $script:fixtureName = $role
    $script:fixturePath = 'C:\TestRuntime\.leadya-native\hash\' + $role + '.exe'
    Assert-WindowState 'SHOWN' "$role window in this installation"
    $script:fixtureTime = $script:clicked.AddSeconds(-1)
    Assert-WindowState 'TIMEOUT' "$role started before this click"
    $script:fixtureTime = [DateTime]::Now
    $script:fixtureWindow = [IntPtr]::Zero
    Assert-WindowState 'TIMEOUT' "$role has no visible main window"
    $script:fixtureWindow = [IntPtr]123
    $script:fixturePath = 'C:\TestRuntimeOther\.leadya-native\hash\' + $role + '.exe'
    Assert-WindowState 'TIMEOUT' "$role belongs to another installation"
    $script:fixturePath = 'C:\TestRuntime\.leadya-native-other\hash\' + $role + '.exe'
    Assert-WindowState 'TIMEOUT' "$role is outside the native directory"
}
foreach ($role in @('java', 'javaw')) {
    $script:fixtureName = $role
    $script:fixturePath = 'C:\TestJava\bin\' + $role + '.exe'
    Assert-WindowState 'SHOWN' "$role compatibility"
}
Assert-WindowState 'CLOSED' 'User closed the notice' $true
