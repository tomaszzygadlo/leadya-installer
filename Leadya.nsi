!define url "https://testowy.backend.leadya.app"
OutFile "../docker/botserver/installers/LeadyaInstaller-TESTOWY_LEADYA_APP.exe"
!define public_origin "https://testowy.leadya.app"

; These settings are rendered by the PowerShell and shell build entry points.

;ALWAYS SAVE THIS FILE WITH UTF-8 WITH BOM ENCODING

;For building this installer you need stable NSIS 3.13 or higher, inetc plugin, nsisunz (unicode version) plugin,
;To build you just need to run this script with makensis.exe (https://nsis.sourceforge.io/Download) and it will create LeadyaInstaller.exe in the same folder as this script.

!addplugindir "./plugins"

!define TEMP1 $R0 ;Temp variable

Var currentLogFileName
Var EmailEncoded
Var PasswordEncoded
Var CheckingProgramVersion
Var CheckingProgramVersionFile
Var CheckingProgramVersionedJar
Var CheckingProgramDownloadFile
Var ChromiumFrontendUrl
Var uninstallRemoveJreCheckbox
Var uninstallRemoveJreState
Var LocalOperatorSid
Var LocalValidationMode
Var LocalValidationJar
Var LocalValidationResult
Var LocalValidationOutput
Var PreviousInstallDirectory
Var PreviousInstallComplete
Var PreviousInstallJar
Var LocalInstallationVerified
Var LocalRuntimeHome
Var LocalCodeHome
Var LocalTrustedHome
Var LocalValidationSeed
Var LocalCodeCleanup
Var LocalDirectoryDialog
Var LocalDirectoryPath
Var LocalDirectoryRestore
Var LocalDirectorySpace
Var LocalDirectorySpaceReady

!define LEADYA_DEFAULT_INSTALL_DIR "$PROGRAMFILES64\Leadya"
!define LEADYA_LOCAL_INSTALL_SIZE_KB 15360
!define /math LEADYA_LOCAL_INSTALL_SIZE_BYTES ${LEADYA_LOCAL_INSTALL_SIZE_KB} * 1024
!define /math LEADYA_LOCAL_INSTALL_SIZE_MB ${LEADYA_LOCAL_INSTALL_SIZE_KB} / 1024

!define LOCAL_INSTALL_STATE_KEY "Software\Leadya\Server"
!define LEADYA_VALIDATOR_SHA256 "01F4E3C836BD359D86D9FA6D7E90F30B34B5FBDA20B94093FE580A9B2D7EFF0A"
!define LEADYA_TRUSTED_DOWNLOADS
; Elevated downloads use an admin-owned package, never a writable code folder or per-user runtime.
!define LEADYA_INSTALL_DOWNLOAD_DIR "$LocalTrustedHome"
!define LEADYA_INSTALL_LOG_DIR "$LocalTrustedHome"

Unicode True
;--------------------------------
;Includes
  !include "LeadyaUtil.nsh"
  !include "winmessages.nsh"

;--------------------------------
;General

  !define chromium_ver "142"

  !define env_hklm 'HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"'
  !define env_hkcu 'HKCU "Environment"'

  ;Name and file
  Name "Leadya"

  ; Identify the real application release; this does not replace a publisher signature.
  !ifndef LEADYA_INSTALLER_VERSION
    !searchparse /file "../BaseModule/src/main/java/pl/softwizard/sellbot/base/MainParameterConstants.java" 'COMMUNICATION_PROTOCOL_VERSION = "' LEADYA_INSTALLER_VERSION '"'
  !endif
  VIProductVersion "${LEADYA_INSTALLER_VERSION}"
  VIAddVersionKey /LANG=1033 "ProductName" "LeadYa Installer"
  VIAddVersionKey /LANG=1033 "CompanyName" "Turbot sp. z o.o."
  VIAddVersionKey /LANG=1033 "FileDescription" "LeadYa Windows Installer"
  VIAddVersionKey /LANG=1033 "FileVersion" "${LEADYA_INSTALLER_VERSION}"
  VIAddVersionKey /LANG=1033 "ProductVersion" "${LEADYA_INSTALLER_VERSION}"
  VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright (c) Turbot sp. z o.o."

  ;Default installation folder
  InstallDir "${LEADYA_DEFAULT_INSTALL_DIR}"

  ; A remembered path is selected only after completed-install validation in .onInit.

  ;Request application privileges for Windows Vista
  RequestExecutionLevel admin

;--------------------------------
;Interface Settings

  !define MUI_ABORTWARNING
  !define MUI_LANGDLL_ALLLANGUAGES
  !define MUI_COMPONENTSPAGE_SMALLDESC
  BrandingText "$(BrandingText) ${url}"

;--------------------------------
;Pages
  !insertmacro MUI_PAGE_WELCOME

  !insertmacro MUI_PAGE_LICENSE "$(LicenseFile)"


  ; Retain MUI translations; nsDialogs adds an explicit restore action to this page.
  !define MUI_DIRECTORYPAGE
  Page custom ShowLocalDirectoryPage LeaveLocalDirectoryPage
  !insertmacro MUI_PAGE_INSTFILES
  !define MUI_FINISHPAGE_RUN
  !define MUI_FINISHPAGE_RUN_FUNCTION RunInstalledLocalApplication
  !insertmacro MUI_PAGE_FINISH

  !insertmacro MUI_UNPAGE_CONFIRM
  UninstPage custom un.SetJreRemovalPage un.SetJreRemovalPageLeave
  !insertmacro MUI_UNPAGE_INSTFILES

;--------------------------------
;InstTypes
!ifndef NOINSTTYPES ; only if not defined
  ;Disable custom InstType
  InstType "Leadya"
  InstType /NOCUSTOM
  ;InstType "Leadya Proxy"
  ;InstType /COMPONENTSONLYONCUSTOM
!endif

AutoCloseWindow false
ShowInstDetails show

;--------------------------------
;Languages
;To add another language, add another !insertmacro MUI_LANGUAGE "Language" line,
;add LicenseLangString License file line with path to license file
;and then write the language strings below

  !insertmacro MUI_LANGUAGE "English"
  !insertmacro MUI_LANGUAGE "Polish"
  !insertmacro MUI_LANGUAGE "German"
  !insertmacro MUI_LANGUAGE "Russian"
  !insertmacro MUI_LANGUAGE "Spanish"
  !insertmacro MUI_LANGUAGE "Italian"
  !insertmacro MUI_LANGUAGE "Ukrainian"
  !insertmacro MUI_LANGUAGE "Czech"

  !include "Language\English.nsh"
  !include "Language\Polish.nsh"
  !include "Language\German.nsh"
  !include "Language\Russian.nsh"
  !include "Language\Spanish.nsh"
  !include "Language\Italian.nsh"
  !include "Language\Ukrainian.nsh"
  !include "Language\Czech.nsh"

!macro LocalValidationMessages LANG DESTINATION FAILED
  LangString LocalDestinationUnsafe ${LANG} "${DESTINATION}"
  LangString LocalInstallationFailed ${LANG} "${FAILED}"
!macroend
!insertmacro LocalValidationMessages ${LANG_POLISH} "Nie można bezpiecznie zainstalować programu w tym folderze. Wybierz lokalizację w Program Files lub prywatnym profilu użytkownika." "Nie udało się potwierdzić poprawnej instalacji. Poprzednia lokalizacja instalacji została zachowana. Sprawdź dziennik instalatora."
!insertmacro LocalValidationMessages ${LANG_ENGLISH} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."
!insertmacro LocalValidationMessages ${LANG_GERMAN} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."
!insertmacro LocalValidationMessages ${LANG_RUSSIAN} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."
!insertmacro LocalValidationMessages ${LANG_SPANISH} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."
!insertmacro LocalValidationMessages ${LANG_ITALIAN} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."
!insertmacro LocalValidationMessages ${LANG_UKRAINIAN} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."
!insertmacro LocalValidationMessages ${LANG_CZECH} "This folder cannot safely host the application. Choose a location in Program Files or your private user profile." "Installation could not be verified. The previously completed installation location has been retained. Check the installer log."

; BEGIN LOCAL INSTALL COMPLETION
!macro ValidatorEnvironment name value failure
  System::Call 'kernel32::SetEnvironmentVariableW(w "${name}", w "${value}") i .r0'
  StrCmp $0 "0" ${failure}
!macroend

!macro InvokePinnedLocalValidator suffix
  !insertmacro ValidatorEnvironment LY0 "$PLUGINSDIR\ValidateLocalInstall.ps1" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY1 "$INSTDIR" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY2 "$LocalValidationMode" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY3 "${public_origin}" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY4 "$LocalValidationJar" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY5 "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY6 "$LocalRuntimeHome" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY7 "$LocalValidationSeed" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY8 "$CheckingProgramDownloadFile" ${suffix}ValidatorFailed
  nsExec::ExecToStack /TIMEOUT=60000 `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "$$ErrorActionPreference='Stop';$$e=12;try{$$f=[IO.File]::Open($$env:LY0,3,1,1);$$h=[Security.Cryptography.SHA256]::Create();if(([BitConverter]::ToString($$h.ComputeHash($$f))-replace'-')-ne'${LEADYA_VALIDATOR_SHA256}'){throw 'HASH'};$$f.Position=0;$$r=[IO.StreamReader]::new($$f,[Text.Encoding]::UTF8,$$true,4096,$$true);$$b=[ScriptBlock]::Create($$r.ReadToEnd());& $$b $$env:LY1 $$env:LY2 $$env:LY3 $$env:LY4 $$env:LY5 $$env:LY6 $$env:LY7 $$env:LY8;$$e=$$LASTEXITCODE}catch{Write-Output 'LOCAL_VALIDATOR_REFUSED'}finally{if($$r){$$r.Dispose()};if($$f){$$f.Dispose()};if($$h){$$h.Dispose()}};exit $$e"`
  Pop $LocalValidationResult
  Pop $LocalValidationOutput
  Goto ${suffix}ValidatorDone
  ${suffix}ValidatorFailed:
  StrCpy $LocalValidationResult "12"
  StrCpy $LocalValidationOutput "LOCAL_VALIDATOR_REFUSED"
  ${suffix}ValidatorDone:
!macroend

Function ValidateLocalInstallation
  StrCpy $LocalValidationSeed ""
  StrCmp $LocalValidationMode "Installed" LocalValidationProtectedSeed
  StrCmp $LocalValidationMode "Installable" LocalValidationProtectedSeed
  StrCmp $LocalValidationMode "Mirror" LocalValidationProtectedSeed
  StrCmp $LocalValidationMode "Links" LocalValidationProtectedSeed
  StrCmp $LocalValidationMode "Seed" LocalValidationProtectedSeed
  StrCmp $LocalValidationMode "Publish" 0 LocalValidationInvoke
  LocalValidationProtectedSeed:
  StrCpy $LocalValidationSeed $LocalTrustedHome
  LocalValidationInvoke:
  !insertmacro InvokePinnedLocalValidator Install
FunctionEnd

Function AllocateLocalDownload
  StrCpy $LocalValidationMode "PackageTemp"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" 0 LocalDownloadAllocationFailed
  ClearErrors
  Return
  LocalDownloadAllocationFailed:
  SetErrors
FunctionEnd

Function RequireTrustedLocalJre
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalJreTrusted
  DetailPrint "Shared Java custody refused: $LocalValidationOutput"
  SetErrorLevel 12
  Abort
  LocalJreTrusted:
FunctionEnd

Function TryResolveLocalRuntimeHome
  GetFullPathName $INSTDIR "$INSTDIR"
  LocalCodeTrimSeparator:
  StrLen $0 $INSTDIR
  IntCmp $0 3 LocalCodePathReady LocalCodePathReady
  StrCpy $0 $INSTDIR 1 -1
  StrCmp $0 "\" 0 LocalCodePathReady
  StrCpy $INSTDIR $INSTDIR -1
  Goto LocalCodeTrimSeparator
  LocalCodePathReady:
  StrCpy $LocalValidationMode "Runtime"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" 0 LocalRuntimeResolutionUnavailable
  ${StrRep} $LocalRuntimeHome $LocalValidationOutput "$\r" ""
  ${StrRep} $LocalRuntimeHome $LocalRuntimeHome "$\n" ""
  StrCpy $LocalValidationMode "Package"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" 0 LocalRuntimeResolutionUnavailable
  ${StrRep} $LocalTrustedHome $LocalValidationOutput "$\r" ""
  ${StrRep} $LocalTrustedHome $LocalTrustedHome "$\n" ""
  Return
  LocalRuntimeResolutionUnavailable:
  StrCpy $LocalRuntimeHome ""
  StrCpy $LocalTrustedHome ""
FunctionEnd

!macro WriteLocalLauncherBatch target
  FileOpen $1 "${target}" w
  FileWrite $1 "@echo off$\r$\n"
  FileWrite $1 "setlocal EnableExtensions DisableDelayedExpansion$\r$\n"
  FileWrite $1 "cd /d $\"%~dp0$\"$\r$\n"
  FileWrite $1 "$\"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe$\" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $\"%~dp0LaunchLocalLeadYa.ps1$\"$\r$\n"
  FileWrite $1 "exit /b %errorlevel%$\r$\n"
  FileClose $1
!macroend

Function ResolveLocalRuntimeHome
  Call TryResolveLocalRuntimeHome
  StrCmp $LocalValidationResult "0" 0 LocalRuntimeResolutionFailed
  Return
  LocalRuntimeResolutionFailed:
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalInstallationFailed)" /SD IDOK
  SetErrorLevel 12
  Quit
FunctionEnd

; BEGIN LOCAL DIRECTORY PAGE
Function ShowLocalDirectoryPage
  !insertmacro MUI_HEADER_TEXT "$(MUI_TEXT_DIRECTORY_TITLE)" "$(MUI_TEXT_DIRECTORY_SUBTITLE)"
  nsDialogs::Create 1018
  Pop $LocalDirectoryDialog
  StrCmp $LocalDirectoryDialog "error" 0 +2
  Abort
  ${NSD_CreateLabel} 0 0 100% 40u "$(^DirText)"
  Pop $0
  ${NSD_CreateGroupBox} 0 45u 100% 43u "$(^DirSubText)"
  Pop $0
  ${NSD_CreateDirRequest} 8u 60u 220u 12u "$INSTDIR"
  Pop $LocalDirectoryPath
  ${NSD_OnChange} $LocalDirectoryPath LocalDirectoryChanged
  ${NSD_CreateBrowseButton} 234u 59u 58u 14u "$(^BrowseBtn)"
  Pop $0
  ${NSD_OnClick} $0 BrowseLocalDirectory
  ${NSD_CreateButton} 8u 94u 284u 16u "$(RestoreDefaultLocation)"
  Pop $LocalDirectoryRestore
  ${NSD_OnClick} $LocalDirectoryRestore RestoreDefaultLocalDirectory
  ${NSD_CreateLabel} 0 120u 100% 10u "$(^SpaceRequired)${LEADYA_LOCAL_INSTALL_SIZE_MB} MB"
  Pop $0
  ${NSD_CreateLabel} 0 130u 100% 10u ""
  Pop $LocalDirectorySpace
  Call UpdateLocalDirectorySpace
  nsDialogs::Show
FunctionEnd

Function ReadLocalDirectoryPath
  Push $0
  Push $1
  Push $2
  ; Normalize before assigning INSTDIR: NSIS otherwise strips forward slashes.
  ${NSD_GetText} $LocalDirectoryPath $1
  StrCpy $0 ""
  LocalDirectoryNormalize:
    StrCpy $2 $1 1
    StrCmp $2 "" LocalDirectoryNormalized
    StrCmp $2 "/" 0 +2
    StrCpy $2 "\"
    StrCpy $0 "$0$2"
    StrCpy $1 $1 "" 1
    Goto LocalDirectoryNormalize
  LocalDirectoryNormalized:
  StrCpy $INSTDIR $0
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

Function LocalDirectoryChanged
  Pop $0
  Call ReadLocalDirectoryPath
  Call UpdateLocalDirectorySpace
FunctionEnd

Function BrowseLocalDirectory
  Pop $0
  nsDialogs::SelectFolderDialog "$(^DirBrowseText)" "$INSTDIR"
  Pop $0
  StrCmp $0 "error" LocalDirectoryBrowseDone
  ${NSD_SetText} $LocalDirectoryPath "$0"
  LocalDirectoryBrowseDone:
FunctionEnd

Function RestoreDefaultLocalDirectory
  Pop $0
  StrCpy $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}"
  ${NSD_SetText} $LocalDirectoryPath "$INSTDIR"
  System::Call 'user32::SetFocus(p $LocalDirectoryPath)'
FunctionEnd

Function UpdateLocalDirectorySpace
  Push $0
  Push $1
  Push $2
  StrCpy $LocalDirectorySpaceReady "0"
  ${NSD_SetText} $LocalDirectorySpace "$(^SpaceAvailable)?"
  StrCpy $0 $INSTDIR
  StrCmp $0 "" LocalDirectorySpaceDone
  ; Query only absolute drive paths on a currently local writable drive type.
  ; Final destination policy still checks reparse points and directory ownership.
  StrCpy $1 $0 1 1
  StrCmp $1 ":" 0 LocalDirectorySpaceDone
  StrCpy $1 $0 1 2
  StrCmp $1 "\" LocalDirectoryDriveRoot
  StrCmp $1 "/" 0 LocalDirectorySpaceDone
  LocalDirectoryDriveRoot:
  StrCpy $1 $0 2
  StrCpy $1 "$1\"
  System::Call 'kernel32::GetDriveTypeW(w r1) i .r2'
  StrCmp $2 "3" LocalDirectoryFindParent
  StrCmp $2 "2" LocalDirectoryFindParent
  StrCmp $2 "6" 0 LocalDirectorySpaceDone
  LocalDirectoryFindParent:
    IfFileExists "$0\*.*" LocalDirectoryQuerySpace
    ${GetParent} "$0" $1
    StrCmp $1 "" LocalDirectorySpaceDone
    StrCmp $0 $1 LocalDirectorySpaceDone
    StrCpy $0 $1
    Goto LocalDirectoryFindParent
  LocalDirectoryQuerySpace:
    System::Call 'kernel32::GetDiskFreeSpaceExW(w r0, *l .r1, p 0, p 0) i .r2'
    StrCmp $2 "0" LocalDirectorySpaceDone
    System::Int64Op $1 / 1048576
    Pop $2
    ${NSD_SetText} $LocalDirectorySpace "$(^SpaceAvailable)$2 MB"
    System::Int64Op $1 < ${LEADYA_LOCAL_INSTALL_SIZE_BYTES}
    Pop $2
    StrCmp $2 "1" LocalDirectorySpaceDone
    StrCpy $LocalDirectorySpaceReady "1"
  LocalDirectorySpaceDone:
  GetDlgItem $0 $HWNDPARENT 1
  EnableWindow $0 $LocalDirectorySpaceReady
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

Function LeaveLocalDirectoryPage
  Call ReadLocalDirectoryPath
  Call UpdateLocalDirectorySpace
  StrCmp $LocalDirectorySpaceReady "1" 0 LocalDirectoryStay
  Call RequireLocalDestination
  Return
  LocalDirectoryStay:
  Abort
FunctionEnd
; END LOCAL DIRECTORY PAGE

Function RequireLocalDestination
  ; The directory page can change $INSTDIR after .onInit selected the initial destination.
  Call TryResolveLocalRuntimeHome
  StrCmp $LocalValidationResult "0" 0 LocalDestinationRefused
  StrCpy $LocalValidationMode "Destination"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalDestinationReady
  LocalDestinationRefused:
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalDestinationUnsafe)$\r$\n$INSTDIR" /SD IDOK
  Abort
  LocalDestinationReady:
FunctionEnd

Function SelectCompletedLocalInstallation
  ; Preserve an explicit command-line /D destination.
  StrCmp $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}" 0 LocalSelectionDone
  ReadRegDWORD $0 HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully"
  StrCmp $0 "1" 0 LocalSelectionDone
  ReadRegStr $1 HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  StrCmp $1 "" LocalSelectionDone
  ReadRegStr $LocalValidationJar HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar"
  StrCpy $INSTDIR $1
  Call TryResolveLocalRuntimeHome
  StrCmp $LocalValidationResult "0" 0 LocalSelectionDefault
  StrCpy $LocalValidationMode "Installable"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalSelectionDone
  LocalSelectionDefault:
  StrCpy $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}"
  LocalSelectionDone:
FunctionEnd

Function PrepareLocalRuntimeHome
  System::Call 'shell32::IsUserAnAdmin() i .r0'
  StrCmp $0 "0" +3
  SetErrorLevel 12
  Abort
  StrCpy $LocalCodeHome $INSTDIR
  StrCpy $INSTDIR $LocalRuntimeHome
  Call RequireLocalInstallHome
  Call PrepareFreshLocalInstallHome
  StrCpy $INSTDIR $LocalCodeHome
FunctionEnd

Function CommitCompletedLocalInstallation
  ReadRegStr $PreviousInstallDirectory HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  ReadRegDWORD $PreviousInstallComplete HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully"
  ReadRegStr $PreviousInstallJar HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar"
  ClearErrors
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "" $INSTDIR
  IfErrors LocalCommitFailed
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar" $LocalValidationJar
  IfErrors LocalCommitFailed
  WriteRegDWORD HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully" 1
  IfErrors LocalCommitFailed
  ; Older clients may still depend on another installation's global home.
  ; The new LOCAL launcher binds its own private process home after verification.
  ReadRegStr $0 ${env_hklm} "LEADYA_HOME"
  StrCmp $0 "" LocalCommitOwnEnvironment
  StrCmp $0 $INSTDIR LocalCommitOwnEnvironment LocalCommitEnvironmentReady
  LocalCommitOwnEnvironment:
  ClearErrors
  ; Last fallible write: a failed/aborted install never redirects other launchers.
  WriteRegStr ${env_hklm} "LEADYA_HOME" $INSTDIR
  IfErrors LocalCommitFailed
  SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
  LocalCommitEnvironmentReady:
  ; Notification is best-effort; the completed registry transaction has already succeeded.
  ClearErrors
  Return
  LocalCommitFailed:
  StrCmp $PreviousInstallDirectory "" 0 +3
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  Goto +2
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "" $PreviousInstallDirectory
  StrCmp $PreviousInstallJar "" 0 +3
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar"
  Goto +2
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar" $PreviousInstallJar
  StrCmp $PreviousInstallComplete "" 0 +3
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully"
  Goto +2
  WriteRegDWORD HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully" $PreviousInstallComplete
  SetErrors
FunctionEnd
; END LOCAL INSTALL COMPLETION

;--------------------------------
; BEGIN LOCAL CLASSIFICATION
; Fresh homes, bound LOCAL homes and recognizable legacy clients support in-place install.
; Unknown retained directories and trusted VPS identities stay refused before mutation.
!include "FileFunc.nsh"
Var LocalHome
Var LocalAncestor
Var LocalFile
Var LocalHandle
Var LocalLine
Var LocalEncoding
Var LocalClassifyCodeOnly

Function RequireLegacyLocalInstallHome
  ; Human-approved in-place upgrade of a recognizable historical LeadYa client.
  ; Ordinary unmarked directories still do not become LOCAL merely because they exist.
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR\bot_files") i .r0'
  IntCmp $0 -1 LegacyLocalHomeRefused
  IntOp $0 $0 & 0x410
  StrCmp $0 16 0 LegacyLocalHomeRefused
  StrCpy $LocalFile "$INSTDIR\LeadyaCheckingProgram.bat"
  IfFileExists "$LocalFile" LegacyLocalLauncherCheck
  StrCpy $LocalFile "$INSTDIR\LeadYaCheckingProgram.exe"
  IfFileExists "$LocalFile" 0 LegacyLocalHomeRefused
  LegacyLocalLauncherCheck:
  System::Call 'kernel32::GetFileAttributesW(w "$LocalFile") i .r0'
  IntCmp $0 -1 LegacyLocalHomeRefused
  IntOp $0 $0 & 0x410
  StrCmp $0 0 0 LegacyLocalHomeRefused
  FindFirst $LocalHandle $LocalLine "$INSTDIR\CheckingProgram*.jar"
  IfErrors LegacyLocalHomeRefused
  FindClose $LocalHandle
  StrCpy $LocalFile "$INSTDIR\$LocalLine"
  System::Call 'kernel32::GetFileAttributesW(w "$LocalFile") i .r0'
  IntCmp $0 -1 LegacyLocalHomeRefused
  IntOp $0 $0 & 0x410
  StrCmp $0 0 0 LegacyLocalHomeRefused
  Return
  LegacyLocalHomeRefused:
  Call RefuseLocalInstallHome
FunctionEnd

Function ReadLocalInstallLine
  ClearErrors
  StrCmp $LocalEncoding "UTF16" 0 LocalReadAnsi
  FileReadUTF16LE $LocalHandle $LocalLine
  Goto LocalTrimLine
  LocalReadAnsi:
  FileRead $LocalHandle $LocalLine
  LocalTrimLine:
  IfErrors LocalLineError
  LocalTrimAgain:
  StrCpy $0 $LocalLine 1 -1
  StrCmp $0 "$\r" LocalTrimLast
  StrCmp $0 "$\n" LocalTrimLast LocalLineDone
  LocalTrimLast:
  StrCpy $LocalLine $LocalLine -1
  Goto LocalTrimAgain
  LocalLineDone:
  Return
  LocalLineError:
  SetErrors
FunctionEnd

Function OpenLocalInstallFile
  System::Call 'kernel32::GetFileAttributesW(w "$LocalFile") i .r0'
  IntCmp $0 -1 LocalInstallRefused
  IntOp $0 $0 & 0x410 ; no directory or reparse point
  StrCmp $0 0 0 LocalInstallRefused
  ClearErrors
  FileOpen $LocalHandle "$LocalFile" r
  IfErrors LocalInstallRefused
  FileSeek $LocalHandle 0 END $0
  IntCmp $0 0 LocalFileRefused LocalFileRefused LocalFileSizeCheck
  LocalFileSizeCheck:
  IntCmp $0 65536 LocalFileSizeOk LocalFileSizeOk LocalFileRefused
  LocalFileSizeOk:
  FileSeek $LocalHandle 0 SET
  FileReadByte $LocalHandle $0
  FileReadByte $LocalHandle $1
  StrCpy $LocalEncoding "ANSI"
  StrCmp $0 255 0 LocalFileRewind
  StrCmp $1 254 0 LocalFileRewind
  StrCpy $LocalEncoding "UTF16"
  LocalFileRewind:
  FileSeek $LocalHandle 0 SET
  Return
  LocalFileRefused:
  FileClose $LocalHandle
  Goto LocalInstallRefused
  LocalInstallRefused:
  Call RefuseLocalInstallHome
FunctionEnd

Function RejectTrustedLocalInstallFile
  IfFileExists "$LocalFile" 0 LocalTrustedDone
  Call OpenLocalInstallFile
  LocalTrustedRead:
  Call ReadLocalInstallLine
  IfErrors LocalTrustedClose
  ; Configuration keys may have leading spaces. Values are never logged.
  LocalTrustedTrim:
  StrCpy $0 $LocalLine 1
  StrCmp $0 " " LocalTrustedTrimOne
  StrCmp $0 "$\t" LocalTrustedTrimOne LocalTrustedKeys
  LocalTrustedTrimOne:
  StrCpy $LocalLine $LocalLine "" 1
  Goto LocalTrustedTrim
  LocalTrustedKeys:
  StrCpy $0 $LocalLine 15
  StrCmp $0 "installationKey" LocalTrustedRefused
  StrCpy $0 $LocalLine 16
  StrCmp $0 "assignedServerId" LocalTrustedRefused
  Goto LocalTrustedRead
  LocalTrustedRefused:
  FileClose $LocalHandle
  Goto LocalInstallRefused
  LocalTrustedClose:
  FileClose $LocalHandle
  LocalTrustedDone:
  Return
  LocalInstallRefused:
  Call RefuseLocalInstallHome
FunctionEnd

Function RequireLocalInstallHome
  GetFullPathName $LocalHome "$INSTDIR"
  StrCpy $LocalAncestor $LocalHome
  LocalCheckAncestor:
  System::Call 'kernel32::GetFileAttributesW(w "$LocalAncestor") i .r0'
  IntCmp $0 -1 LocalAncestorParent
  IntOp $0 $0 & 0x400
  StrCmp $0 0 0 LocalInstallRefused
  LocalAncestorParent:
  ${GetParent} "$LocalAncestor" $0
  StrCmp $0 "" LocalAncestorsOk
  StrCmp $0 $LocalAncestor LocalAncestorsOk
  StrCpy $LocalAncestor $0
  Goto LocalCheckAncestor
  LocalAncestorsOk:
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR") i .r0'
  IntCmp $0 -1 LocalHomeMissing
  IntOp $0 $0 & 0x10
  StrCmp $0 0 LocalInstallRefused
  LocalHomeMissing:
  IfFileExists "$INSTDIR\leadya-local-install.txt" LocalBoundHome
  ; A missing marker needs either an empty home or a recognized legacy in-place upgrade.
  IfFileExists "$INSTDIR" 0 LocalHomeAccepted
  FindFirst $LocalHandle $LocalLine "$INSTDIR\*.*"
  IfErrors LocalFreshDone
  LocalFreshEntry:
  StrCmp $LocalLine "." LocalFreshNext
  StrCmp $LocalLine ".." LocalFreshNext
  FindClose $LocalHandle
  ; Selected code directories may contain unrelated files; private runtime homes may not.
  StrCmp $LocalClassifyCodeOnly "1" LocalCheckHomeIdentity
  Call RequireLegacyLocalInstallHome
  Goto LocalCheckHomeIdentity
  LocalFreshNext:
  FindNext $LocalHandle $LocalLine
  IfErrors LocalFreshClose LocalFreshEntry
  LocalFreshClose:
  FindClose $LocalHandle
  LocalFreshDone:
  Goto LocalHomeAccepted
  LocalBoundHome:
  StrCpy $LocalFile "$INSTDIR\leadya-local-install.txt"
  Call OpenLocalInstallFile
  Call ReadLocalInstallLine
  IfErrors LocalBoundRefused
  StrCmpS $LocalLine "LOCAL" 0 LocalBoundRefused
  Call ReadLocalInstallLine
  IfErrors LocalBoundRefused
  StrCmp $LocalLine $LocalHome 0 LocalBoundRefused
  Call ReadLocalInstallLine
  IfErrors LocalBoundRefused
  StrCmpS $LocalLine "${public_origin}" 0 LocalBoundRefused
  Call ReadLocalInstallLine
  IfErrors LocalBoundValid LocalBoundRefused
  LocalBoundRefused:
  FileClose $LocalHandle
  Goto LocalInstallRefused
  LocalBoundValid:
  FileClose $LocalHandle
  LocalCheckHomeIdentity:
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR\bot_files") i .r0'
  IntCmp $0 -1 LocalCheckIdentity
  IntOp $0 $0 & 0x400
  StrCmp $0 0 0 LocalInstallRefused
  LocalCheckIdentity:
  StrCpy $LocalFile "$INSTDIR\bot_files\bot.properties"
  Call RejectTrustedLocalInstallFile
  StrCpy $LocalFile "$INSTDIR\bot.properties.backup"
  Call RejectTrustedLocalInstallFile
  LocalHomeAccepted:
  Return
  LocalInstallRefused:
  Call RefuseLocalInstallHome
FunctionEnd

Function RefuseLocalInstallHome
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(ERROR_somethingWentWrong) [LOCAL_HOME]$\r$\n$INSTDIR" /SD IDOK
  SetErrorLevel 10
  Quit
FunctionEnd
; END LOCAL CLASSIFICATION

; BEGIN FRESH LOCAL PRIVACY
Var LocalPrivatePath

Function RequireLocalPrivatePathOwner
  System::Call 'kernel32::GetFileAttributesW(w "$LocalPrivatePath") i .r0'
  IntCmp $0 -1 LocalPrivatePathOwnerReady
  IntOp $0 $0 & 0x400
  StrCmp $0 0 0 LocalPrivatePathOwnerRefused
  AccessControl::GetFileOwner /SID "$LocalPrivatePath"
  Pop $0
  StrCmp $0 $LocalOperatorSid LocalPrivatePathOwnerReady
  StrCmp $0 "S-1-5-18" LocalPrivatePathOwnerReady
  StrCmp $0 "S-1-5-32-544" LocalPrivatePathOwnerReady
  LocalPrivatePathOwnerRefused:
  Call RefuseLocalInstallPrivacy
  LocalPrivatePathOwnerReady:
  Return
FunctionEnd

Function SecureLocalPrivatePath
  System::Call 'kernel32::GetFileAttributesW(w "$LocalPrivatePath") i .r0'
  IntCmp $0 -1 LocalPrivatePathSecured
  Call RequireLocalPrivatePathOwner
  AccessControl::DisableFileInheritance "$LocalPrivatePath"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivatePathFailed
  AccessControl::ClearOnFile "$LocalPrivatePath" "$LocalLine" "FullAccess"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivatePathFailed
  AccessControl::GrantOnFile "$LocalPrivatePath" "(SY)" "FullAccess"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivatePathFailed
  AccessControl::GrantOnFile "$LocalPrivatePath" "(BA)" "FullAccess"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivatePathFailed
  LocalPrivatePathSecured:
  Return
  LocalPrivatePathFailed:
  Call RefuseLocalInstallPrivacy
FunctionEnd

Function PrepareFreshLocalInstallHome
  ; This legacy producer is callable only by an ordinary user. The elevated installer is read-only here.
  System::Call 'shell32::IsUserAnAdmin() i .r0'
  StrCmp $0 "0" +3
  SetErrorLevel 12
  Abort
  ; Classification has accepted fresh or recognized legacy LOCAL. Never repair a bound home.
  IfFileExists "$INSTDIR\leadya-local-install.txt" LocalPrivacyReady
  CreateDirectory "$INSTDIR"
  AccessControl::GetCurrentUserName
  Pop $0
  StrCmp $0 "error" LocalPrivacyFailure
  StrCpy $LocalLine $0
  AccessControl::NameToSid "$LocalLine"
  Pop $LocalOperatorSid
  StrCmp $LocalOperatorSid "error" LocalPrivacyFailure
  AccessControl::GetFileOwner /SID "$INSTDIR"
  Pop $0
  StrCmp $0 $LocalOperatorSid LocalPrivateOwnerAccepted
  StrCmp $0 "S-1-5-18" LocalPrivateOwnerAccepted
  StrCmp $0 "S-1-5-32-544" 0 LocalPrivacyFailure
  LocalPrivateOwnerAccepted:
  ; Check custody before changing any existing ACL. Credentials and profile bytes stay intact.
  StrCpy $LocalPrivatePath "$INSTDIR\bot_files"
  Call RequireLocalPrivatePathOwner
  StrCpy $LocalPrivatePath "$INSTDIR\bot_files\bot.properties"
  Call RequireLocalPrivatePathOwner
  StrCpy $LocalPrivatePath "$INSTDIR\bot.properties.backup"
  Call RequireLocalPrivatePathOwner
  AccessControl::DisableFileInheritance "$INSTDIR"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivacyFailure
  AccessControl::ClearOnFile "$INSTDIR" "$LocalLine" "FullAccess"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivacyFailure
  AccessControl::GrantOnFile "$INSTDIR" "(SY)" "FullAccess"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivacyFailure
  AccessControl::GrantOnFile "$INSTDIR" "(BA)" "FullAccess"
  Pop $0
  StrCmp $0 "ok" 0 LocalPrivacyFailure
  StrCpy $LocalPrivatePath "$INSTDIR\bot_files"
  Call SecureLocalPrivatePath
  StrCpy $LocalPrivatePath "$INSTDIR\bot_files\bot.properties"
  Call SecureLocalPrivatePath
  StrCpy $LocalPrivatePath "$INSTDIR\bot.properties.backup"
  Call SecureLocalPrivatePath
  LocalPrivacyReady:
  Return
  LocalPrivacyFailure:
  Call RefuseLocalInstallPrivacy
FunctionEnd

Function RefuseLocalInstallPrivacy
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(ERROR_somethingWentWrong) [LOCAL_PRIVACY]" /SD IDOK
  SetErrorLevel 11
  Quit
FunctionEnd
; END FRESH LOCAL PRIVACY

;--------------------------------
;Installer Sections

Section "Leadya" SecServer
SectionIn 1
  Call RequireLocalDestination
  StrCpy $LocalClassifyCodeOnly "1"
  Call RequireLocalInstallHome
  StrCpy $LocalClassifyCodeOnly "0"
  StrCpy $LocalValidationMode "PackagePrepare"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" +3
  SetErrorLevel 12
  Abort

  ${LogLine} "(SecServer) Setting output path"
  SetOutPath "$LocalTrustedHome"

  ${LogLine} "(SecServer) Installing JRE"
  !insertmacro InstallJRE
  ; The elevated phase never initializes user-owned runtime data.
  DetailPrint $(LOG_installingLeadyaServer)

  DetailPrint "$(LOG_checkingProgramVersion)"
  ${LogLine} "(SecServer) Downloading CheckingProgram version from ${url}/currentClientVersion"
  ClearErrors
  Call AllocateLocalDownload
  IfErrors LocalPayloadFailure
  ${StrRep} $CheckingProgramVersionFile $LocalValidationOutput "$\r" ""
  ${StrRep} $CheckingProgramVersionFile $CheckingProgramVersionFile "$\n" ""
  inetc::get "${url}/currentClientVersion" "$CheckingProgramVersionFile" /END
  Pop $0
  StrCmp $0 "OK" VersionOk
  StrCmp $0 "Ok" VersionOk
  ${LogLine} "(SecServer) Downloading version failed, fallback to legacy. Error: $0"
  StrCpy $CheckingProgramVersion "legacy"
  Goto VersionResolved
  VersionOk:
  FileOpen $1 "$CheckingProgramVersionFile" r
  FileRead $1 $CheckingProgramVersion
  FileClose $1
  ${StrRep} $CheckingProgramVersion $CheckingProgramVersion "$\r" ""
  ${StrRep} $CheckingProgramVersion $CheckingProgramVersion "$\n" ""
  StrCmp $CheckingProgramVersion "" 0 VersionResolved
  StrCpy $CheckingProgramVersion "legacy"
  VersionResolved:
  StrCpy $CheckingProgramVersionedJar "$LocalTrustedHome\CheckingProgram-$CheckingProgramVersion.jar"
  ClearErrors
  Call AllocateLocalDownload
  IfErrors LocalPayloadFailure
  ${StrRep} $CheckingProgramDownloadFile $LocalValidationOutput "$\r" ""
  ${StrRep} $CheckingProgramDownloadFile $CheckingProgramDownloadFile "$\n" ""

  ${LogLine} "(SecServer) Downloading Leadya Server from ${url}/CheckingProgram.jar to $CheckingProgramVersionedJar"
  DetailPrint "$(LOG_downloadingCheckingProgram)"
  inetc::get /CAPTION "$(LOG_downloadingCheckingProgram)" /POPUP "CheckingProgram" "${url}/CheckingProgram.jar" "$CheckingProgramDownloadFile" /END
  Pop $0
  StrCmp $0 "OK" LeadyaOk
  ${LogLine} "(SecServer) Downloading Leadya failed"
  ${LogLine} "(SecServer) Error: $0"
  DetailPrint "$0" ;print error message to log
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(ERROR_somethingWentWrong) $0" /SD IDOK
  Abort
  LeadyaOk:
  DetailPrint "$(LOG_downloadedCheckingProgram)"
  ${LogLine} "(SecServer) Downloading Leadya finished"
  ClearErrors
  StrCpy $LocalValidationJar "CheckingProgram-$CheckingProgramVersion.jar"
  StrCpy $LocalValidationMode "PackageSeed"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" 0 LocalPayloadFailure
  ClearErrors
  !insertmacro WriteLocalLauncherBatch "$LocalTrustedHome\LeadyaCheckingProgram.bat"
  IfErrors LocalPayloadFailure
  File /oname=$LocalTrustedHome\LaunchLocalLeadYa.ps1 "LaunchLocalLeadYa.ps1"
  File /oname=$LocalTrustedHome\ValidateLocalInstall.ps1 "ValidateLocalInstall.ps1"
  File /oname=$LocalTrustedHome\LocalProfileRecovery.ps1 "LocalProfileRecovery.ps1"
  File /oname=$LocalTrustedHome\LaunchLocalLeadYa.vbs "LaunchLocalLeadYa.vbs"
  File /oname=$LocalTrustedHome\leadya-nova-icon.ico "leadya-nova-icon.ico"
  File /oname=$LocalTrustedHome\ThirdPartyNotices.txt "ThirdPartyNotices.txt"
  FileOpen $1 "$LocalTrustedHome\leadya-local-origin.txt" w
  FileWrite $1 "${public_origin}$\r$\n"
  FileClose $1
  IfErrors LocalPayloadFailure
  FileOpen $1 "$LocalTrustedHome\leadya-code-home.txt" w
  FileWriteUTF16LE /BOM $1 "$INSTDIR$\r$\n"
  FileClose $1
  IfErrors LocalPayloadFailure
  ; Chromium is provisioned by the ordinary client through ChromiumProvisioner when needed.

  ;Create uninstaller
  ${LogLine} "(SecServer) Creating uninstaller"
  WriteUninstaller "$LocalTrustedHome\Uninstall.exe"

  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Leadya" \
                 "DisplayName" "Leadya"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Leadya" \
                 "UninstallString" "$\"$LocalTrustedHome\Uninstall.exe$\""
  StrCpy $LocalValidationJar "CheckingProgram-$CheckingProgramVersion.jar"
  DetailPrint "$(LOG_verifyingInstallation)"
  StrCpy $LocalValidationMode "Installable"
  Call ValidateLocalInstallation
  ${LogLine} "(SecServer) Final validation: $LocalValidationResult $LocalValidationOutput"
  StrCmp $LocalValidationResult "0" LocalInstallationVerified
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalInstallationFailed)" /SD IDOK
  SetErrorLevel 12
  Abort
  LocalInstallationVerified:
  StrCpy $LocalInstallationVerified "1"
  ${LogLine} "(SecServer) Finished"
  Goto LocalPayloadDone
  LocalPayloadFailure:
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalInstallationFailed)" /SD IDOK
  SetErrorLevel 12
  Abort
  LocalPayloadDone:
SectionEnd



Function RunInstalledLocalApplication
  ; The installation is complete. Cancellation/offline authentication never rolls it back.
  SetOutPath "$LocalTrustedHome"
  ShellExecAsUser::ShellExecAsUser "open" "$SYSDIR\wscript.exe" '$"$LocalTrustedHome\LaunchLocalLeadYa.vbs$"' SW_HIDE
FunctionEnd

;--------------------------------
Section "-Leadya Proxy" SecProxy
SectionIn 2

  ${LogLine} "(SecProxy) Setting output path"
  SetOutPath "$INSTDIR"

  ${LogLine} "(SecProxy) Installing JRE"
  !insertmacro InstallJRE

  ${LogLine} "(SecProxy) Storing installation folder in registry"
  WriteRegStr HKCU "Software\Leadya\Proxy" "" $INSTDIR

  ${LogLine} "(SecProxy) Creating uninstaller"
  WriteUninstaller "$INSTDIR\UninstallProxy.exe"

  ${LogLine} "(SecProxy) Finished"
SectionEnd

;--------------------------------
Section "-Commit completed installation" SecLocalCommit
SectionIn 1
  StrCmp $LocalInstallationVerified "1" 0 LocalInstallationSuccessDone
  DetailPrint "$(LOG_finishingInstallation)"
  ; Publish the launch version only after the complete payload passed the real startup policy.
  StrCpy $LocalValidationMode "Publish"
  Call ValidateLocalInstallation
  ${LogLine} "(SecLocalCommit) Publish: $LocalValidationResult $LocalValidationOutput"
  StrCmp $LocalValidationResult "0" 0 LocalInstallationCommitFailed
  StrCpy $LocalValidationMode "Mirror"
  Call ValidateLocalInstallation
  ${LogLine} "(SecLocalCommit) Mirror: $LocalValidationResult $LocalValidationOutput"
  StrCmp $LocalValidationResult "0" 0 LocalInstallationCommitFailed
  StrCpy $LocalValidationMode "Links"
  Call ValidateLocalInstallation
  ${LogLine} "(SecLocalCommit) Links: $LocalValidationResult $LocalValidationOutput"
  StrCmp $LocalValidationResult "0" 0 LocalInstallationCommitFailed
  ${StrRep} $LocalValidationOutput $LocalValidationOutput "$\r" ""
  ${StrRep} $LocalValidationOutput $LocalValidationOutput "$\n" ""
  StrCmp $LocalValidationOutput "LOCAL_LINKS_DEFERRED" 0 LocalSharedLinksDone
  DetailPrint "$(LOG_sharedShortcutDeferred)"
  DetailPrint "$LocalTrustedHome\LaunchLocalLeadYa.vbs"
  LocalSharedLinksDone:
  ClearErrors
  Call CommitCompletedLocalInstallation
  IfErrors LocalInstallationCommitFailed
  ${LogLine} "(SecLocalCommit) Installation state committed; environment policy completed"
  LocalInstallationSuccessDone:
  Goto LocalInstallationCommitDone
  LocalInstallationCommitFailed:
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalInstallationFailed)" /SD IDOK
  SetErrorLevel 13
  Abort
  LocalInstallationCommitDone:
SectionEnd

;Installer Functions

Function CleanupLocalDownloadFiles
  StrCmp $CheckingProgramVersionFile "" +2
  Delete "$CheckingProgramVersionFile"
  StrCmp $CheckingProgramDownloadFile "" +2
  Delete "$CheckingProgramDownloadFile"
  StrCmp $JreArchivePath "" +2
  Delete "$JreArchivePath"
FunctionEnd

Function .onInstFailed
  Call CleanupLocalDownloadFiles
FunctionEnd

Function .onInstSuccess
  Call CleanupLocalDownloadFiles
FunctionEnd


Function .onInit
  !insertmacro MUI_LANGDLL_DISPLAY

  ${GetTime} "" "L" $0 $1 $2 $3 $4 $5 $6
  StrCpy $currentLogFileName "LeadyaInstaller-$2-$1-$0-$4-$5-$6.log"


  InitPluginsDir
  File /oname=$PLUGINSDIR\ValidateLocalInstall.ps1 "ValidateLocalInstall.ps1"
  Call SelectCompletedLocalInstallation
  Call ResolveLocalRuntimeHome

  ;SectionSetFlags ${SecServer} ${SF_RO}
  SectionSetFlags ${SecProxy} ${SF_RO}

  SectionSetSize ${SecServer} ${LEADYA_LOCAL_INSTALL_SIZE_KB}
FunctionEnd


;--------------------------------
;Uninstaller Section

Function un.onInit
  ; The registered uninstaller lives in the protected package; the chosen code folder is only a copy.
  InitPluginsDir
  File /oname=$PLUGINSDIR\ValidateLocalInstall.ps1 "ValidateLocalInstall.ps1"
  StrCpy $LocalTrustedHome $INSTDIR
  StrCpy $LocalCodeCleanup "0"
  StrCpy $LocalValidationJar ""
  StrCpy $LocalValidationMode "Uninstall"
  StrCpy $LocalValidationSeed ""
  !insertmacro InvokePinnedLocalValidator UninstallBind
  StrCpy $0 $LocalValidationResult
  StrCpy $INSTDIR $LocalValidationOutput
  StrCmp $0 "0" 0 UninstallBindingRefused
  ${StrRep} $INSTDIR $INSTDIR "$\r" ""
  ${StrRep} $INSTDIR $INSTDIR "$\n" ""
  FileOpen $1 "$LocalTrustedHome\checking_program_version.txt" r
  IfErrors UninstallBindingReady
  FileRead $1 $LocalValidationJar
  FileClose $1
  ${StrRep} $LocalValidationJar $LocalValidationJar "$\r" ""
  ${StrRep} $LocalValidationJar $LocalValidationJar "$\n" ""
  StrCpy $LocalValidationJar "CheckingProgram-$LocalValidationJar.jar"
  StrCpy $LocalValidationMode "CodeCleanup"
  !insertmacro InvokePinnedLocalValidator UninstallCleanup
  StrCpy $0 $LocalValidationResult
  StrCmp $0 "0" 0 UninstallBindingReady
  StrCpy $LocalCodeCleanup "1"
  Goto UninstallBindingReady
  UninstallBindingRefused:
  SetErrorLevel 12
  Quit
  UninstallBindingReady:
FunctionEnd

Section "Uninstall" SecUninstallServer
  ; Code directories may contain unrelated files and legacy data. Retain those on uninstall.
  StrCmp $LocalCodeCleanup "1" 0 LocalUninstallCodeDone
  StrCmp $LocalValidationJar "" +2
  Delete /REBOOTOK "$INSTDIR\$LocalValidationJar"
  Delete /REBOOTOK "$INSTDIR\Uninstall.exe"
  Delete /REBOOTOK "$INSTDIR\CheckingProgram.jar"
  Delete /REBOOTOK "$INSTDIR\checking_program_version.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-local-install.txt"
  Delete /REBOOTOK "$INSTDIR\LeadyaCheckingProgram.bat"
  Delete /REBOOTOK "$INSTDIR\LaunchLocalLeadYa.ps1"
  Delete /REBOOTOK "$INSTDIR\ValidateLocalInstall.ps1"
  Delete /REBOOTOK "$INSTDIR\LocalProfileRecovery.ps1"
  Delete /REBOOTOK "$INSTDIR\LaunchLocalLeadYa.vbs"
  Delete /REBOOTOK "$INSTDIR\leadya-nova-icon.ico"
  Delete /REBOOTOK "$INSTDIR\leadya-local-origin.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-runtime-home.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-code-home.txt"
  LocalUninstallCodeDone:

  IntCmp $uninstallRemoveJreState ${BST_CHECKED} 0 SkipSharedJreRemoval 0
  StrCpy $LocalValidationMode "Jre"
  !insertmacro InvokePinnedLocalValidator UninstallJre
  StrCmp $LocalValidationResult "0" 0 SkipSharedJreRemoval
  RMDir /r /REBOOTOK "${LEADYA_SHARED_JRE_DIR}"
  Goto SharedJreHandled

  SkipSharedJreRemoval:
  SharedJreHandled:

  StrCpy $LocalValidationMode "Unlink"
  StrCpy $LocalValidationSeed $LocalTrustedHome
  !insertmacro InvokePinnedLocalValidator UninstallLinks
  ReadRegStr $0 HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  StrCmp $0 $INSTDIR 0 LocalUninstallShortcutsDone
  DeleteRegKey HKCU "${LOCAL_INSTALL_STATE_KEY}"
  LocalUninstallShortcutsDone:
  StrCmp $LocalTrustedHome "" LocalUninstallPackageDone
  ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Leadya" "UninstallString"
  StrCmp $0 '$\"$LocalTrustedHome\Uninstall.exe$\"' 0 +2
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Leadya"
  Delete /REBOOTOK "$LocalTrustedHome\$LocalValidationJar"
  Delete /REBOOTOK "$LocalTrustedHome\LeadyaCheckingProgram.bat"
  Delete /REBOOTOK "$LocalTrustedHome\LaunchLocalLeadYa.ps1"
  Delete /REBOOTOK "$LocalTrustedHome\ValidateLocalInstall.ps1"
  Delete /REBOOTOK "$LocalTrustedHome\LocalProfileRecovery.ps1"
  Delete /REBOOTOK "$LocalTrustedHome\LaunchLocalLeadYa.vbs"
  Delete /REBOOTOK "$LocalTrustedHome\leadya-nova-icon.ico"
  Delete /REBOOTOK "$LocalTrustedHome\ThirdPartyNotices.txt"
  Delete /REBOOTOK "$LocalTrustedHome\leadya-code-home.txt"
  Delete /REBOOTOK "$LocalTrustedHome\leadya-local-origin.txt"
  Delete /REBOOTOK "$LocalTrustedHome\checking_program_version.txt"
  Delete /REBOOTOK "$LocalTrustedHome\Uninstall.exe"
  RMDir "$LocalTrustedHome"
  LocalUninstallPackageDone:

SectionEnd

Function un.SetJreRemovalPage
  !insertmacro MUI_HEADER_TEXT "Java runtime" "LeadYa can be removed without deleting the shared JDK."
  nsDialogs::Create 1018
  Pop $0

  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 24u "LeadYa zostanie odinstalowana, ale wspoldzielone JDK domyslnie pozostanie w systemie.$\r$\n$\r$\nZaznacz opcje ponizej tylko wtedy, gdy na pewno chcesz usunac rowniez Java."
  Pop $0

  ${NSD_CreateCheckbox} 0 34u 100% 12u "Usun tez wspoldzielone JDK z $PROGRAMFILES64\Java\jdk-17.0.9+9-jre"
  Pop $uninstallRemoveJreCheckbox
  ${NSD_Uncheck} $uninstallRemoveJreCheckbox

  ${NSD_CreateLabel} 0 52u 100% 22u "Uwaga: usuniecie JDK moze wymagac restartu komputera, jesli pliki Javy sa aktualnie uzywane przez LeadYa lub inne programy."
  Pop $0

  nsDialogs::Show
FunctionEnd

Function un.SetJreRemovalPageLeave
  ${NSD_GetState} $uninstallRemoveJreCheckbox $uninstallRemoveJreState
FunctionEnd
