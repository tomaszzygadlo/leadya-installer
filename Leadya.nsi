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
Var CheckingProgramVersion
Var CheckingProgramVersionFile
Var CheckingProgramVersionedJar
Var CheckingProgramDownloadFile
Var ChromiumFrontendUrl
Var uninstallRemoveJreCheckbox
Var uninstallRemoveJreState
Var uninstallRemoveProfileCheckbox
Var uninstallRemoveProfileState
Var uninstallRemoveInstallersCheckbox
Var uninstallRemoveInstallersState
Var uninstallOwnerPid
Var uninstallOwnerTime
Var uninstallOwnerExecutable
Var uninstallUserCommand
Var uninstallDeadlineTick
Var LocalValidationMode
Var LocalValidationJar
Var LocalValidationResult
Var LocalValidationOutput
Var PreviousInstallDirectory
Var PreviousInstallComplete
Var PreviousInstallJar
Var LocalInstallationVerified
Var LocalRuntimeHome
Var LocalTrustedHome
Var LocalValidationSeed
Var LocalCodeCleanup
Var LocalDirectoryDialog
Var LocalDirectoryPath
Var LocalDirectoryRestore
Var LocalDirectorySpace
Var LocalDirectorySpaceReady
Var LocalFailureCode
Var LocalIdentityRoot
Var LocalIdentityAdopted
Var LocalAdoptedProfile
Var LocalValidationInput
Var LocalDestinationAccepted
Var PreviousInstallIdentity
Var LocalShowRetry

!define LEADYA_DEFAULT_INSTALL_DIR "$LOCALAPPDATA\Programs\Leadya"
!define LEADYA_LOCAL_INSTALL_SIZE_KB 15360
!define /math LEADYA_LOCAL_INSTALL_SIZE_BYTES ${LEADYA_LOCAL_INSTALL_SIZE_KB} * 1024
!define /math LEADYA_LOCAL_INSTALL_SIZE_MB ${LEADYA_LOCAL_INSTALL_SIZE_KB} / 1024

!define LOCAL_INSTALL_STATE_KEY "Software\Leadya\Server"
!define LOCAL_UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Leadya"
; The entry written by the old machine-wide installer. It is only read, to find a computer that must keep its profile.
!define LOCAL_LEGACY_UNINSTALL 'HKLM "${LOCAL_UNINSTALL_KEY}"'
!define LEADYA_CHROME_DOWNLOAD_PAGE "https://www.google.com/chrome/"
!define LEADYA_VALIDATOR_SHA256 "EB833E05B35ACA063CA749CD329E8EBADFEE180DDDC86FB6BFC5C2CC8F7E5D78"
; Downloads and logs stay in this user's private package, never in the chosen code folder.
!define LEADYA_INSTALL_LOG_DIR "$LocalTrustedHome"

Unicode True
;--------------------------------
;Includes
  !include "LeadyaUtil.nsh"
  !include "winmessages.nsh"

;--------------------------------
;General

  !define chromium_ver "142"

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

  ; Everything is installed into this user's own folders, so administrator rights are never requested.
  RequestExecutionLevel user

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
  !define MUI_FINISHPAGE_SHOWREADME ""
  !define MUI_FINISHPAGE_SHOWREADME_TEXT "$(ChromeFinishOption)"
  !define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
  !define MUI_FINISHPAGE_SHOWREADME_FUNCTION OpenGoogleChromeDownloadPage
  !define MUI_PAGE_CUSTOMFUNCTION_SHOW ConfigureChromeFinishPage
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

!macro LocalValidationMessages LANG DESTINATION FAILED SUPPORT ELEVATED
  LangString LocalDestinationUnsafe ${LANG} "${DESTINATION}"
  LangString LocalInstallationFailed ${LANG} "${FAILED}"
  LangString LocalSupportCode ${LANG} "${SUPPORT}"
  LangString LocalRunNormally ${LANG} "${ELEVATED}"
!macroend
!define LEADYA_FAILED_PL "Nie udało się dokończyć instalacji LeadYa. Twoje logowanie i ustawienia LeadYa są zachowane.$\r$\n$\r$\nUruchom instalator jeszcze raz. Jeśli ten komunikat wróci, zrób zdjęcie tego okna i wyślij je do nas."
!define LEADYA_FAILED_EN "LeadYa could not finish the installation. Your LeadYa sign-in and settings are kept.$\r$\n$\r$\nRun the installer again. If this message comes back, take a photo of this window and send it to us."
!define LEADYA_SUPPORT_EN "Code for technical support:"
!insertmacro LocalValidationMessages ${LANG_POLISH} "LeadYa nie może zainstalować się w tym folderze. Wybierz inny folder albo zostaw ten, który proponujemy." "${LEADYA_FAILED_PL}" "Kod dla pomocy technicznej:" "Uruchom instalator zwyczajnie, klikając go dwa razy. Nie wybieraj opcji Uruchom jako administrator."
!insertmacro LocalValidationMessages ${LANG_ENGLISH} "LeadYa cannot be installed in this folder. Choose another folder, or keep the one we suggest." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Start the installer the normal way, by double-clicking it. Do not choose Run as administrator."
!insertmacro LocalValidationMessages ${LANG_GERMAN} "LeadYa kann nicht in diesem Ordner installiert werden. Wählen Sie einen anderen Ordner oder behalten Sie den vorgeschlagenen." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Starten Sie das Installationsprogramm ganz normal mit einem Doppelklick. Wählen Sie nicht Als Administrator ausführen."
!insertmacro LocalValidationMessages ${LANG_RUSSIAN} "LeadYa нельзя установить в эту папку. Выберите другую папку или оставьте предложенную." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Запустите установщик как обычно, двойным щелчком. Не выбирайте пункт Запуск от имени администратора."
!insertmacro LocalValidationMessages ${LANG_SPANISH} "LeadYa no se puede instalar en esta carpeta. Elige otra carpeta o deja la que te proponemos." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Abre el instalador de la forma normal, con doble clic. No elijas Ejecutar como administrador."
!insertmacro LocalValidationMessages ${LANG_ITALIAN} "LeadYa non può essere installato in questa cartella. Scegli un'altra cartella o lascia quella proposta." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Avvia il programma di installazione nel modo normale, con un doppio clic. Non scegliere Esegui come amministratore."
!insertmacro LocalValidationMessages ${LANG_UKRAINIAN} "LeadYa не можна встановити в цю папку. Виберіть іншу папку або залиште запропоновану." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Запустіть інсталятор як зазвичай, подвійним клацанням. Не вибирайте пункт Запуск від імені адміністратора."
!insertmacro LocalValidationMessages ${LANG_CZECH} "LeadYa nelze nainstalovat do této složky. Vyberte jinou složku nebo nechte tu, kterou navrhujeme." "${LEADYA_FAILED_EN}" "${LEADYA_SUPPORT_EN}" "Spusťte instalační program normálně dvojitým kliknutím. Nevybírejte Spustit jako správce."

; BEGIN LOCAL INSTALL COMPLETION
; The installers of every address share HKCU\Software\Leadya\Server. The identity and the adoption stop carry the
; address in their value name, and a value of another address is never read or changed. A value written before,
; without an address, is still read as before. The identity of that kind is never changed; a stop of that kind is
; forgotten only when it names this installer's package, whose id already includes the address.
!define LOCAL_IDENTITY_VALUE "IdentityRoot@${public_origin}"
!define LOCAL_LEGACY_IDENTITY_VALUE "IdentityRoot"
!define LOCAL_ADOPT_STOPPED_VALUE "AdoptStopped@${public_origin}"
!define LOCAL_LEGACY_ADOPT_STOPPED_VALUE "AdoptStopped"
; The saved installation folder whose check stopped once for a retry; the same stop twice in a row gives way.
!define LOCAL_RESOLVE_STOPPED_VALUE "ResolveStopped@${public_origin}"
; Forgets the adoption stop of the old package whose id is in $2; $1 is overwritten.
!macro ForgetLocalAdoptionStop
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_ADOPT_STOPPED_VALUE}"
  ReadRegStr $1 HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_LEGACY_ADOPT_STOPPED_VALUE}"
  StrCmp $1 $2 0 +2
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_LEGACY_ADOPT_STOPPED_VALUE}"
  ClearErrors
!macroend
!macro ValidatorEnvironment name value failure
  System::Call 'kernel32::SetEnvironmentVariableW(w "${name}", w "${value}") i .r0'
  StrCmp $0 "0" ${failure}
!macroend

!macro InvokePinnedLocalValidator suffix
  Push $1
  Push $2
  Push $3
  Push $4
  Push $5
  !insertmacro ValidatorEnvironment LY0 "$PLUGINSDIR\ValidateLocalInstall.ps1" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY1 "$INSTDIR" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY2 "$LocalValidationMode" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY3 "${public_origin}" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY4 "$LocalValidationJar" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY5 "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY6 "$LocalRuntimeHome" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY7 "$LocalValidationSeed" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY8 "$CheckingProgramDownloadFile" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY9 "$LocalValidationInput" ${suffix}ValidatorFailed
  !insertmacro ValidatorEnvironment LY10 "$LocalIdentityRoot" ${suffix}ValidatorFailed
  ; ASCII envelope avoids nsExec's ANSI conversion of Unicode installation paths.
  ; The end marker refuses a truncated stack value instead of accepting a shorter path.
  nsExec::ExecToStack /TIMEOUT=60000 `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "$$ErrorActionPreference='Stop';$$e=12;try{$$f=[IO.File]::Open($$env:LY0,3,1,1);$$h=[Security.Cryptography.SHA256]::Create();if(([BitConverter]::ToString($$h.ComputeHash($$f))-replace'-')-ne'${LEADYA_VALIDATOR_SHA256}'){throw 'HASH'};$$f.Position=0;$$r=[IO.StreamReader]::new($$f,[Text.Encoding]::UTF8,$$true,4096,$$true);$$b=[ScriptBlock]::Create($$r.ReadToEnd());& $$b $$env:LY1 $$env:LY2 $$env:LY3 $$env:LY4 $$env:LY5 $$env:LY6 $$env:LY7 $$env:LY8 $$true $$env:LY9 $$env:LY10;$$e=$$LASTEXITCODE}catch{[Console]::Out.Write('LYV1:'+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('LOCAL_VALIDATOR_REFUSED'))+':END')}finally{if($$r){$$r.Dispose()};if($$f){$$f.Dispose()};if($$h){$$h.Dispose()}};exit $$e"`
  Pop $LocalValidationResult
  Pop $LocalValidationOutput
  StrCpy $0 $LocalValidationOutput 5
  StrCmp $0 "LYV1:" 0 ${suffix}ValidatorFailed
  StrCpy $0 $LocalValidationOutput 4 -4
  StrCmp $0 ":END" 0 ${suffix}ValidatorFailed
  StrCpy $0 $LocalValidationOutput -4 5
  StrCpy $1 0
  System::Call 'crypt32::CryptStringToBinaryW(w r0, i 0, i 1, p 0, *i .r1, p 0, p 0) i .r2'
  StrCmp $2 0 ${suffix}ValidatorFailed
  IntCmp $1 ${NSIS_MAX_STRLEN} 0 0 ${suffix}ValidatorFailed
  IntOp $2 $1 + 2
  System::Alloc $2
  Pop $3
  StrCmp $3 0 ${suffix}ValidatorFailed
  IntOp $4 $3 + $1
  System::Call '*$4(&i2 0)'
  System::Call 'crypt32::CryptStringToBinaryW(w r0, i 0, i 1, p r3, *i r1, p 0, p 0) i .r2'
  StrCmp $2 0 ${suffix}ValidatorDecodeFailed
  System::Call 'kernel32::lstrcpynW(w .r0, p r3, i ${NSIS_MAX_STRLEN}) p'
  StrCpy $LocalValidationOutput $0
  System::Free $3
  Goto ${suffix}ValidatorDone
  ${suffix}ValidatorDecodeFailed:
  System::Free $3
  ${suffix}ValidatorFailed:
  StrCpy $LocalValidationResult "12"
  StrCpy $LocalValidationOutput "LOCAL_VALIDATOR_REFUSED"
  ${suffix}ValidatorDone:
  Pop $5
  Pop $4
  Pop $3
  Pop $2
  Pop $1
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

!macro ShowLocalStepFailure CODE STAGE
  ; A LOCAL step that fails outside the pinned validator reports its own fixed support code.
  StrCpy $LocalValidationResult "12"
  StrCpy $LocalValidationOutput "${CODE}"
  StrCpy $LocalValidationMode "${STAGE}"
  Call ShowLocalInstallationFailure
!macroend

Function ShowLocalInstallationFailure
  ; A failed validator emits only a fixed LOCAL_* code, never a path, ACL or configuration value.
  ${StrRep} $LocalFailureCode $LocalValidationOutput "$\r" ""
  ${StrRep} $LocalFailureCode $LocalFailureCode "$\n" ""
  StrCmp $LocalValidationResult "0" LocalFailureStep
  StrCpy $0 $LocalFailureCode 6
  StrCmpS $0 "LOCAL_" LocalFailureCodeReady
  LocalFailureStep:
  StrCpy $LocalFailureCode "LOCAL_STEP_FAILED"
  LocalFailureCodeReady:
  ; Before .onInit resolves the protected package there is no log folder; the dialog carries the code.
  StrCmp $LocalTrustedHome "" LocalFailureShow
  ${LogLine} "(Failure) $LocalValidationMode $LocalValidationResult $LocalFailureCode"
  LocalFailureShow:
  DetailPrint "$(LocalSupportCode) $LocalFailureCode ($LocalValidationMode)"
  StrCmp $LocalFailureCode "LOCAL_ELEVATED_RUNTIME" 0 LocalFailureAdoption
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalRunNormally)$\r$\n$\r$\n$(LocalSupportCode) $LocalFailureCode" /SD IDOK
  Return
  LocalFailureAdoption:
  ; A stop for a retry: nothing was installed yet; the person only has to close the installer and start it once more.
  StrCmp $LocalShowRetry "1" 0 LocalFailureGeneral
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalAdoptionRetry)$\r$\n$\r$\n$(LocalSupportCode) $LocalFailureCode ($LocalValidationMode)" /SD IDOK
  Return
  LocalFailureGeneral:
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalInstallationFailed)$\r$\n$\r$\n$(LocalSupportCode) $LocalFailureCode ($LocalValidationMode)" /SD IDOK
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
  Call ShowLocalInstallationFailure
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
  ; A profile adopted in this run binds the runtime; otherwise the runtime resolution chooses.
  StrCpy $LocalValidationInput $LocalAdoptedProfile
  Call ValidateLocalInstallation
  StrCpy $LocalValidationInput ""
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
  Call ShowLocalInstallationFailure
  SetErrorLevel 12
  Quit
FunctionEnd

Function ResolveLocalIdentity
  ; A computer moved from the old Program Files install keeps its profile through that program's identity.
  ; The current user's own earlier choice wins, because the old uninstaller may have been used since.
  StrCpy $LocalIdentityAdopted "0"
  StrCpy $LocalAdoptedProfile ""
  ReadRegStr $LocalIdentityRoot HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}"
  StrCmp $LocalIdentityRoot "" 0 LocalIdentitySaved
  ReadRegStr $LocalIdentityRoot HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_LEGACY_IDENTITY_VALUE}"
  StrCmp $LocalIdentityRoot "" LocalIdentityAdoption
  LocalIdentitySaved:
  ; A saved identity is dropped only when no profile location of it holds the marker any more (a profile deleted
  ; outside the uninstaller). Any other answer keeps it; the runtime resolution then reports its own code.
  StrCpy $LocalValidationMode "Identity"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalIdentityReady
  ${StrRep} $0 $LocalValidationOutput "$\r" ""
  ${StrRep} $0 $0 "$\n" ""
  StrCmp $0 "LOCAL_IDENTITY_PROFILE_GONE" 0 LocalIdentityReady
  StrCpy $LocalIdentityRoot ""
  LocalIdentityAdoption:
  ClearErrors
  ReadRegStr $0 ${LOCAL_LEGACY_UNINSTALL} "UninstallString"
  IfErrors LocalIdentityReady
  StrCpy $1 $0 1
  StrCmp $1 '"' 0 LocalIdentityReady
  StrCpy $1 $0 15 -15
  StrCmp $1 '\Uninstall.exe"' 0 LocalIdentityReady
  StrCpy $LocalValidationInput $0 -15 1
  StrCpy $LocalValidationMode "Adopt"
  Call ValidateLocalInstallation
  ; The old package id names a stop, so the same stop twice in a row can give way.
  StrCpy $2 $LocalValidationInput "" -64
  StrCpy $LocalValidationInput ""
  ${StrRep} $0 $LocalValidationOutput "$\r" ""
  ${StrRep} $0 $0 "$\n" ""
  StrCmp $LocalValidationResult "0" LocalIdentityAdopted
  ; Only a failure that a retry can clear stops here: a read error, or a validator that timed out or was refused.
  ; Nothing to adopt, or a package or profile that the launcher could not use either, gives a fresh identity;
  ; the old profile stays on disk untouched, and an earlier stop is over.
  StrCmp $0 "LOCAL_VALIDATION_FAILED" LocalIdentityRetry
  StrCmp $0 "LOCAL_VALIDATOR_REFUSED" LocalIdentityRetry
  !insertmacro ForgetLocalAdoptionStop
  Goto LocalIdentityReady
  LocalIdentityRetry:
  ReadRegStr $1 HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_ADOPT_STOPPED_VALUE}"
  StrCmp $1 $2 LocalIdentityGiveWay
  ReadRegStr $1 HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_LEGACY_ADOPT_STOPPED_VALUE}"
  StrCmp $1 $2 0 LocalIdentityStop
  LocalIdentityGiveWay:
  ; The second stop on the same package must not block the computer for good.
  !insertmacro ForgetLocalAdoptionStop
  Goto LocalIdentityReady
  LocalIdentityStop:
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_ADOPT_STOPPED_VALUE}" $2
  StrCpy $LocalShowRetry "1"
  Call ShowLocalInstallationFailure
  SetErrorLevel 12
  Quit
  LocalIdentityAdopted:
  ; "<identity>|<profile>": the guard at the commit protects exactly the profile Adopt verified.
  StrCpy $LocalIdentityRoot $0
  StrCpy $3 0
  LocalIdentitySplit:
  StrCpy $4 $0 1 $3
  StrCmp $4 "" LocalIdentitySplitDone
  StrCmp $4 "|" 0 +5
  StrCpy $LocalIdentityRoot $0 $3
  IntOp $3 $3 + 1
  StrCpy $LocalAdoptedProfile $0 "" $3
  Goto LocalIdentitySplitDone
  IntOp $3 $3 + 1
  Goto LocalIdentitySplit
  LocalIdentitySplitDone:
  StrCpy $LocalIdentityAdopted "1"
  !insertmacro ForgetLocalAdoptionStop
  LocalIdentityReady:
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
  ; Leaving the page and starting the section check the same folder; once is enough.
  StrCmp $LocalDestinationAccepted $INSTDIR LocalDestinationReady
  ; The directory page can change $INSTDIR after .onInit selected the initial destination.
  Call TryResolveLocalRuntimeHome
  StrCmp $LocalValidationResult "0" 0 LocalDestinationRefused
  StrCpy $LocalValidationMode "Destination"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalDestinationAllowed
  LocalDestinationRefused:
  ${StrRep} $LocalFailureCode $LocalValidationOutput "$\r" ""
  ${StrRep} $LocalFailureCode $LocalFailureCode "$\n" ""
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(LocalDestinationUnsafe)$\r$\n$INSTDIR$\r$\n$\r$\n$(LocalSupportCode) $LocalFailureCode" /SD IDOK
  Abort
  LocalDestinationAllowed:
  StrCpy $LocalDestinationAccepted $INSTDIR
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
  StrCmp $LocalValidationResult "0" 0 LocalSelectionFailed
  StrCpy $LocalValidationMode "Installable"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalSelectionKept
  LocalSelectionFailed:
  ; Only a failure that a retry can clear stops here: a read error (a scanner holding a file), a validator that
  ; timed out or was refused, or too little free memory for Java. The saved folder then stays for the next run.
  ; A lasting defect of the saved folder or its profile chooses the default folder at once, as does the same stop
  ; twice in a row.
  ${StrRep} $0 $LocalValidationOutput "$\r" ""
  ${StrRep} $0 $0 "$\n" ""
  StrCmp $0 "LOCAL_VALIDATION_FAILED" LocalSelectionRetry
  StrCmp $0 "LOCAL_VALIDATOR_REFUSED" LocalSelectionRetry
  StrCmp $0 "LOCAL_JAVA_MEMORY" LocalSelectionRetry
  ; A damaged package (a file an antivirus program quarantined) is rebuilt by installing into the same folder:
  ; PackagePrepare and this installer's section write it again. Outside Program Files the folder is the identity, so
  ; the default folder would start with an empty profile. The folder is kept only when it has a profile to keep and
  ; this user can still install there; a bare remembered path never becomes the install folder.
  StrCmp $0 "LOCAL_PACKAGE_MISSING" LocalSelectionPackage
  StrCmp $0 "LOCAL_PACKAGE_BINDING" LocalSelectionPackage
  StrCmp $0 "LOCAL_PAYLOAD_MISSING" LocalSelectionPackage LocalSelectionDefault
  LocalSelectionPackage:
  StrCmp $LocalRuntimeHome "" LocalSelectionDefault
  IfFileExists "$LocalRuntimeHome\leadya-local-install.txt" 0 LocalSelectionDefault
  StrCpy $LocalValidationMode "Destination"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" LocalSelectionKept LocalSelectionDefault
  LocalSelectionRetry:
  ReadRegStr $2 HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_RESOLVE_STOPPED_VALUE}"
  StrCmp $2 $INSTDIR LocalSelectionDefault
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_RESOLVE_STOPPED_VALUE}" $INSTDIR
  StrCpy $LocalShowRetry "1"
  Call ShowLocalInstallationFailure
  SetErrorLevel 12
  Quit
  LocalSelectionDefault:
  StrCpy $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}"
  LocalSelectionKept:
  ; Any answer other than a retryable failure ends an earlier stop.
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_RESOLVE_STOPPED_VALUE}"
  ClearErrors
  LocalSelectionDone:
FunctionEnd

Function CommitCompletedLocalInstallation
  ReadRegStr $PreviousInstallDirectory HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  ReadRegDWORD $PreviousInstallComplete HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully"
  ReadRegStr $PreviousInstallJar HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar"
  ReadRegStr $PreviousInstallIdentity HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}"
  ClearErrors
  StrCmp $LocalIdentityRoot "" 0 LocalCommitIdentity
  ; A saved identity whose profile was gone was dropped in .onInit; it is forgotten together with this commit.
  ; An older value without an address may belong to another address and stays.
  StrCmp $PreviousInstallIdentity "" LocalCommitLocation
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}"
  IfErrors LocalCommitFailed
  Goto LocalCommitLocation
  LocalCommitIdentity:
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}" $LocalIdentityRoot
  IfErrors LocalCommitFailed
  LocalCommitLocation:
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "" $INSTDIR
  IfErrors LocalCommitFailed
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar" $LocalValidationJar
  IfErrors LocalCommitFailed
  WriteRegDWORD HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully" 1
  IfErrors LocalCommitFailed
  ; A completed installation ends any earlier stop of its adoption, also on the saved-identity path without Adopt,
  ; and any earlier stop of the check of its saved folder.
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_ADOPT_STOPPED_VALUE}"
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_RESOLVE_STOPPED_VALUE}"
  ClearErrors
  ; Nothing is stored in the environment: the launcher binds its own process to the private home.
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
  StrCmp $PreviousInstallIdentity "" 0 +3
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}"
  Goto +2
  WriteRegStr HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}" $PreviousInstallIdentity
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
  StrCmp $LocalValidationResult "0" LocalPackagePrepared
  Call ShowLocalInstallationFailure
  SetErrorLevel 12
  Abort
  LocalPackagePrepared:

  ${LogLine} "(SecServer) Setting output path"
  SetOutPath "$LocalTrustedHome"

  ${LogLine} "(SecServer) Installing JRE"
  !insertmacro InstallJRE
  ; The launcher prepares this user's runtime data at the first start.
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
  ; Names the step for support if writing the protected package files fails below.
  StrCpy $LocalValidationMode "PackageFiles"
  ClearErrors
  !insertmacro WriteLocalLauncherBatch "$LocalTrustedHome\LeadyaCheckingProgram.bat"
  IfErrors LocalPayloadFailure
  File /oname=$LocalTrustedHome\LaunchLocalLeadYa.ps1 "LaunchLocalLeadYa.ps1"
  File /oname=$LocalTrustedHome\InstallGoogleChrome.ps1 "InstallGoogleChrome.ps1"
  File /oname=$LocalTrustedHome\ValidateLocalInstall.ps1 "ValidateLocalInstall.ps1"
  File /oname=$LocalTrustedHome\LocalProfileRecovery.ps1 "LocalProfileRecovery.ps1"
  File /oname=$LocalTrustedHome\UninstallLocalLeadYa.ps1 "UninstallLocalLeadYa.ps1"
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
  Delete "$LocalTrustedHome\leadya-identity-root.txt"
  StrCmp $LocalIdentityRoot "" LocalIdentityFileDone
  FileOpen $1 "$LocalTrustedHome\leadya-identity-root.txt" w
  FileWriteUTF16LE /BOM $1 "$LocalIdentityRoot$\r$\n"
  FileClose $1
  IfErrors LocalPayloadFailure
  LocalIdentityFileDone:
  ; Chromium is provisioned by the ordinary client through ChromiumProvisioner when needed.

  ;Create uninstaller
  ${LogLine} "(SecServer) Creating uninstaller"
  WriteUninstaller "$LocalTrustedHome\Uninstall.exe"

  WriteRegStr HKCU "${LOCAL_UNINSTALL_KEY}" "DisplayName" "Leadya"
  WriteRegStr HKCU "${LOCAL_UNINSTALL_KEY}" "UninstallString" "$\"$LocalTrustedHome\Uninstall.exe$\""
  StrCpy $LocalValidationJar "CheckingProgram-$CheckingProgramVersion.jar"
  DetailPrint "$(LOG_verifyingInstallation)"
  StrCpy $LocalValidationMode "Installable"
  Call ValidateLocalInstallation
  ${LogLine} "(SecServer) Final validation: $LocalValidationResult $LocalValidationOutput"
  StrCmp $LocalValidationResult "0" LocalInstallationVerified
  Call ShowLocalInstallationFailure
  SetErrorLevel 12
  Abort
  LocalInstallationVerified:
  StrCpy $LocalInstallationVerified "1"
  ${LogLine} "(SecServer) Finished"
  Goto LocalPayloadDone
  LocalPayloadFailure:
  Call ShowLocalInstallationFailure
  SetErrorLevel 12
  Abort
  LocalPayloadDone:
SectionEnd



Function RunInstalledLocalApplication
  ; The installation is complete. Cancellation/offline authentication never rolls it back.
  ; The finish action uses the hidden PowerShell entry point directly, independently
  ; of Windows Script Host's optional VBS engine and its per-user file association.
  SetOutPath "$LocalTrustedHome"
  ExecShell "open" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$LocalTrustedHome\LaunchLocalLeadYa.ps1"' SW_HIDE
FunctionEnd

Function ConfigureChromeFinishPage
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$LocalTrustedHome\InstallGoogleChrome.ps1" -DetectOnly'
  Pop $0
  Pop $1
  StrCmp $0 "0" 0 ChromeNotInstalled
  SendMessage $mui.FinishPage.ShowReadme ${BM_SETCHECK} ${BST_UNCHECKED} 0
  ShowWindow $mui.FinishPage.ShowReadme ${SW_HIDE}
  ChromeNotInstalled:
FunctionEnd

Function OpenGoogleChromeDownloadPage
  ; The person downloads and installs Chrome from Google themselves; the installer never does it silently.
  ExecShell "open" "${LEADYA_CHROME_DOWNLOAD_PAGE}"
FunctionEnd

;--------------------------------
Section "-Commit completed installation" SecLocalCommit
SectionIn 1
  StrCmp $LocalInstallationVerified "1" 0 LocalInstallationSuccessDone
  DetailPrint "$(LOG_finishingInstallation)"
  StrCmp $LocalIdentityRoot "" LocalAdoptionGuardDone
  ; The old uninstaller stays listed. Its ticked-by-default option must not remove the profile now in use,
  ; so the profile is guarded before anything of this installation is published. A profile adopted in this run
  ; must still be there; a saved one that vanished meanwhile gets no guard, and the next installation drops it.
  StrCmp $LocalIdentityAdopted "1" LocalAdoptionGuard
  IfFileExists "$LocalRuntimeHome\leadya-local-install.txt" 0 LocalAdoptionGuardDone
  LocalAdoptionGuard:
  StrCpy $LocalValidationMode "AdoptGuard"
  ; An adopted profile is guarded exactly where Adopt verified it, which can differ from the chosen runtime.
  StrCpy $LocalValidationInput $LocalAdoptedProfile
  Call ValidateLocalInstallation
  StrCpy $LocalValidationInput ""
  ${LogLine} "(SecLocalCommit) AdoptGuard: $LocalValidationResult $LocalValidationOutput"
  StrCmp $LocalValidationResult "0" 0 LocalInstallationCommitFailed
  LocalAdoptionGuardDone:
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
  StrCpy $LocalValidationMode "Registry"
  ClearErrors
  Call CommitCompletedLocalInstallation
  IfErrors LocalInstallationCommitFailed
  ${LogLine} "(SecLocalCommit) Installation state committed"
  LocalInstallationSuccessDone:
  Goto LocalInstallationCommitDone
  LocalInstallationCommitFailed:
  Call ShowLocalInstallationFailure
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
  StrCmp $JreStagePath "" +2
  RMDir /r "$JreStagePath"
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
  Call ResolveLocalIdentity
  Call SelectCompletedLocalInstallation
  Call ResolveLocalRuntimeHome

  SectionSetSize ${SecServer} ${LEADYA_LOCAL_INSTALL_SIZE_KB}
FunctionEnd


;--------------------------------
;Uninstaller Section

Function un.onInit
  ; The registered uninstaller lives in the protected package; the chosen code folder is only a copy.
  InitPluginsDir
  File /oname=$PLUGINSDIR\ValidateLocalInstall.ps1 "ValidateLocalInstall.ps1"
  CreateDirectory "$PLUGINSDIR\user-cleanup"
  File /oname=$PLUGINSDIR\user-cleanup\UninstallLocalLeadYa.ps1 "UninstallLocalLeadYa.ps1"
  StrCpy $uninstallRemoveProfileState ${BST_CHECKED}
  StrCpy $uninstallRemoveInstallersState ${BST_CHECKED}
  StrCpy $uninstallRemoveJreState ${BST_UNCHECKED}
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
  IfFileExists "$LocalTrustedHome\leadya-identity-root.txt" 0 UninstallIdentityReady
  FileOpen $1 "$LocalTrustedHome\leadya-identity-root.txt" r
  FileReadUTF16LE $1 $LocalIdentityRoot
  FileClose $1
  ${StrRep} $LocalIdentityRoot $LocalIdentityRoot "$\r" ""
  ${StrRep} $LocalIdentityRoot $LocalIdentityRoot "$\n" ""
  UninstallIdentityReady:
  ClearErrors
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

Function un.CleanupLocalUser
  Delete "$PLUGINSDIR\user-cleanup\leadya-user-cleanup-result.txt"
  FileOpen $0 "$PLUGINSDIR\user-cleanup\leadya-user-cleanup-result.txt" w
  IfErrors LocalUninstallUserFailed
  FileClose $0
  System::Call 'kernel32::GetCurrentProcessId() i .r0'
  StrCpy $uninstallOwnerPid $0
  System::Call 'kernel32::GetCurrentProcess() p .r0'
  System::Call 'kernel32::GetProcessTimes(p r0, *l .r1, *l .r2, *l .r3, *l .r4) i .r5'
  StrCmp $5 0 LocalUninstallUserFailed
  StrCpy $uninstallOwnerTime $1
  System::Call 'kernel32::GetModuleFileNameW(p 0, w .r0, i ${NSIS_MAX_STRLEN}) i .r1'
  StrCpy $uninstallOwnerExecutable $0
  System::Call 'kernel32::GetTickCount64() l .r0'
  System::Int64Op $0 + 90000
  Pop $uninstallDeadlineTick
  ; Use an existing public working directory while the selected program is removed.
  SetOutPath "$TEMP"
  StrCpy $uninstallUserCommand '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$PLUGINSDIR\user-cleanup\UninstallLocalLeadYa.ps1" -InstallDirectory "$INSTDIR" -IdentityRoot "$LocalIdentityRoot" -PublicOrigin "${public_origin}" -RemoveProfile $uninstallRemoveProfileState -RemoveInstallers $uninstallRemoveInstallersState -ResultFile "$PLUGINSDIR\user-cleanup\leadya-user-cleanup-result.txt" -OwnerProcessId $uninstallOwnerPid -OwnerCreationTime $uninstallOwnerTime -OwnerExecutable "$uninstallOwnerExecutable" -DeadlineTick $uninstallDeadlineTick'
  ; The uninstaller already runs as the ordinary user. nsExec keeps the child console hidden.
  nsExec::ExecToStack /TIMEOUT=90000 `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" $uninstallUserCommand`
  Pop $0
  Pop $1
  ClearErrors
  FileOpen $1 "$PLUGINSDIR\user-cleanup\leadya-user-cleanup-result.txt" r
  IfErrors LocalUninstallUserFailed
  FileRead $1 $2
  FileClose $1
  StrCmp $2 "LOCAL_UNINSTALL_OK:END" LocalUninstallUserDone
  DetailPrint "$2"
  LocalUninstallUserFailed:
  MessageBox MB_OK|MB_ICONEXCLAMATION "Nie mozna bezpiecznie usunac wybranych danych. Zamknij LeadYa i jej przegladarki, a nastepnie ponow deinstalacje. Pliki programu pozostaly na miejscu." /SD IDOK
  SetErrorLevel 12
  Abort
  LocalUninstallUserDone:
FunctionEnd

Section "Uninstall" SecUninstallServer
  ; Private user data is removed only by the ordinary interactive user's token.
  ; Refuse before touching installed code if a marked profile is still in use.
  Call un.CleanupLocalUser
  ; Code directories may contain unrelated files and legacy data. Retain those on uninstall.
  StrCmp $LocalCodeCleanup "1" 0 LocalUninstallCodeDone
  StrCmp $LocalValidationJar "" +2
  Delete /REBOOTOK "$INSTDIR\$LocalValidationJar"
  Delete /REBOOTOK "$INSTDIR\Uninstall.exe"
  Delete /REBOOTOK "$INSTDIR\CheckingProgram.jar"
  Delete /REBOOTOK "$INSTDIR\CheckingProgram-*.jar"
  Delete /REBOOTOK "$INSTDIR\checking_program_version.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-local-install.txt"
  Delete /REBOOTOK "$INSTDIR\LeadyaCheckingProgram.bat"
  Delete /REBOOTOK "$INSTDIR\LaunchLocalLeadYa.ps1"
  Delete /REBOOTOK "$INSTDIR\InstallGoogleChrome.ps1"
  Delete /REBOOTOK "$INSTDIR\ValidateLocalInstall.ps1"
  Delete /REBOOTOK "$INSTDIR\LocalProfileRecovery.ps1"
  Delete /REBOOTOK "$INSTDIR\UninstallLocalLeadYa.ps1"
  Delete /REBOOTOK "$INSTDIR\LaunchLocalLeadYa.vbs"
  Delete /REBOOTOK "$INSTDIR\leadya-nova-icon.ico"
  Delete /REBOOTOK "$INSTDIR\leadya-local-origin.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-runtime-home.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-code-home.txt"
  Delete /REBOOTOK "$INSTDIR\leadya-identity-root.txt"
  Delete /REBOOTOK "$INSTDIR\ThirdPartyNotices.txt"
  RMDir "$INSTDIR"
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
  ; A stop of this address's adoption or of the check of its saved folder means nothing once its installation is gone.
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_ADOPT_STOPPED_VALUE}"
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_RESOLVE_STOPPED_VALUE}"
  ReadRegStr $0 HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  StrCmp $0 $INSTDIR 0 LocalUninstallShortcutsDone
  ; A kept profile must stay reachable when LeadYa is installed again.
  ReadRegStr $1 HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}"
  StrCmp $1 "" 0 +2
  ReadRegStr $1 HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_LEGACY_IDENTITY_VALUE}"
  StrCmp $1 "" LocalUninstallForgetState
  IntCmp $uninstallRemoveProfileState ${BST_CHECKED} LocalUninstallForgetState
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar"
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully"
  Goto LocalUninstallShortcutsDone
  LocalUninstallForgetState:
  ; Only this address's values go; installers of other addresses keep theirs in the same key.
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" ""
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "CheckingProgramJar"
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "InstalledSuccessfully"
  DeleteRegValue HKCU "${LOCAL_INSTALL_STATE_KEY}" "${LOCAL_IDENTITY_VALUE}"
  DeleteRegKey /ifnosubkeys /ifnovalues HKCU "${LOCAL_INSTALL_STATE_KEY}"
  LocalUninstallShortcutsDone:
  StrCmp $LocalTrustedHome "" LocalUninstallPackageDone
  ReadRegStr $0 HKCU "${LOCAL_UNINSTALL_KEY}" "UninstallString"
  StrCmp $0 '$\"$LocalTrustedHome\Uninstall.exe$\"' 0 +2
  DeleteRegKey HKCU "${LOCAL_UNINSTALL_KEY}"
  ; This exact package passed the binding/ancestor checks in un.onInit.
  ; Include retained versions, installer logs and partial downloads, not just the current JAR.
  RMDir /r /REBOOTOK "$LocalTrustedHome"
  LocalUninstallPackageDone:

SectionEnd

Function un.SetJreRemovalPage
  !insertmacro MUI_HEADER_TEXT "Odinstaluj LeadYa" "Wybierz dane i pobrane pliki do usuniecia."
  nsDialogs::Create 1018
  Pop $0

  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 24u "Pliki programu zostana usuniete. Odznacz wybrana opcje, jesli chcesz zachowac profil lub pobrane instalatory. Przed usunieciem profilu zamknij LeadYa."
  Pop $0

  ${NSD_CreateCheckbox} 0 34u 100% 12u "Usun moj profil LeadYa: ustawienia, logowanie i dane przegladarek"
  Pop $uninstallRemoveProfileCheckbox
  ${NSD_SetState} $uninstallRemoveProfileCheckbox $uninstallRemoveProfileState

  ${NSD_CreateCheckbox} 0 54u 100% 12u "Usun pobrane instalatory LeadYa z folderu Pobrane"
  Pop $uninstallRemoveInstallersCheckbox
  ${NSD_SetState} $uninstallRemoveInstallersCheckbox $uninstallRemoveInstallersState

  ${NSD_CreateCheckbox} 0 74u 100% 12u "$(UninstallRemoveJava)"
  Pop $uninstallRemoveJreCheckbox
  ${NSD_SetState} $uninstallRemoveJreCheckbox $uninstallRemoveJreState

  ${NSD_CreateLabel} 0 96u 100% 26u "Java domyslnie pozostaje, poniewaz moze sluzyc innym programom. Usuniecie plikow aktualnie uzywanych moze wymagac restartu komputera."
  Pop $0

  ${NSD_OnBack} un.SetJreRemovalPageLeave
  nsDialogs::Show
FunctionEnd

Function un.SetJreRemovalPageLeave
  ${NSD_GetState} $uninstallRemoveJreCheckbox $uninstallRemoveJreState
  ${NSD_GetState} $uninstallRemoveProfileCheckbox $uninstallRemoveProfileState
  ${NSD_GetState} $uninstallRemoveInstallersCheckbox $uninstallRemoveInstallersState
FunctionEnd
