Option Explicit
Dim shell, files, folder, command, version
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
command = """" & shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & folder & "\LaunchLocalLeadYa.ps1"""
If WScript.Arguments.Count > 0 Then
    version = WScript.Arguments(0)
    Dim pattern
    Set pattern = New RegExp
    pattern.Pattern = "^[A-Za-z0-9.]+$"
    If Not pattern.Test(version) Then WScript.Quit 12
    command = command & " -RequestedVersion " & version
End If
shell.Run command, 0, False
