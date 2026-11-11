;Includes
;--------------------------------
!include "MUI2.nsh"
!include 'LogicLib.nsh'
!include "WinMessages.nsh"
!include "FileFunc.nsh"
!include nsDialogs.nsh
!include Util.nsh

!define LEADYA_BUNDLED_JRE_DIR "jdk-17.0.21+9-jre"
!define LEADYA_SHARED_JRE_PARENT "$LOCALAPPDATA\LeadYa\Java"
!define LEADYA_SHARED_JRE_DIR "${LEADYA_SHARED_JRE_PARENT}\${LEADYA_BUNDLED_JRE_DIR}"
Var JreArchiveHandle
Var JreArchivePath
Var JreStagePath

!define SetTitleBar "!insertmacro SetTitleBar"
!macro SetTitlebar Str
  SendMessage $HWNDPARENT ${WM_SETTEXT} 0 "STR:${Str}"
!macroend

!define LogLine "!insertmacro LogLine"
!macro LogLine Str
  Push `${Str}`
  !ifdef LEADYA_INSTALL_LOG_DIR
    Push `${LEADYA_INSTALL_LOG_DIR}\$currentLogFileName`
  !else
    Push `$INSTDIR\$currentLogFileName`
  !endif
  Call WriteLineToFile
!macroend

!define StrRep "!insertmacro StrRep"
!macro StrRep output string old new
    Push `${string}`
    Push `${old}`
    Push `${new}`
    !ifdef __UNINSTALL__
        Call un.StrRep
    !else
        Call StrRep
    !endif
    Pop ${output}
!macroend
 
!macro Func_StrRep un
    Function ${un}StrRep
        Exch $R2 ;new
        Exch 1
        Exch $R1 ;old
        Exch 2
        Exch $R0 ;string
        Push $R3
        Push $R4
        Push $R5
        Push $R6
        Push $R7
        Push $R8
        Push $R9
 
        StrCpy $R3 0
        StrLen $R4 $R1
        StrLen $R6 $R0
        StrLen $R9 $R2
        loop:
            StrCpy $R5 $R0 $R4 $R3
            StrCmp $R5 $R1 found
            StrCmp $R3 $R6 done
            IntOp $R3 $R3 + 1 ;move offset by 1 to check the next character
            Goto loop
        found:
            StrCpy $R5 $R0 $R3
            IntOp $R8 $R3 + $R4
            StrCpy $R7 $R0 "" $R8
            StrCpy $R0 $R5$R2$R7
            StrLen $R6 $R0
            IntOp $R3 $R3 + $R9 ;move offset by length of the replacement string
            Goto loop
        done:
 
        Pop $R9
        Pop $R8
        Pop $R7
        Pop $R6
        Pop $R5
        Pop $R4
        Pop $R3
        Push $R0
        Push $R1
        Pop $R0
        Pop $R1
        Pop $R0
        Pop $R2
        Exch $R1
    FunctionEnd
!macroend
!insertmacro Func_StrRep ""
!insertmacro Func_StrRep "un."

!insertmacro GetTime

!macro InstallJRE
  StrCpy $LocalValidationMode "JrePrepare"
  Call RequireTrustedLocalJre
  ; A working shared runtime must remain available to other installed clients.
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" 0 CheckOldJre
  ; LOCAL uses the pinned helper's isolated child environment. A failed probe never deletes a shared JRE.
  StrCpy $LocalValidationMode "JreProbe"
  Call RequireTrustedLocalJre
  Goto Finish
  CheckOldJre:
  ; Replace only an unusable shared JRE.
  ${LogLine} "(InstallJRE) Checking if old JRE folder exists"
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\*.*" RemoveOldJRE
  Goto RemoveLegacyLocalJre

  RemoveOldJRE:
  ${LogLine} "(InstallJRE) Old JRE folder found, attempting to remove..."
  DetailPrint $(LOG_removingOldJre)
  RMDir /r "${LEADYA_SHARED_JRE_DIR}"
  ${LogLine} "(InstallJRE) RMDir /r command executed"

  ; Check if removal was successful
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\*.*" RemovalFailed
  ${LogLine} "(InstallJRE) Old JRE folder successfully removed"
  Goto RemoveLegacyLocalJre

  RemovalFailed:
  ${LogLine} "(InstallJRE) Failed to remove old JRE folder completely, attempting to clear contents..."
  DetailPrint $(LOG_clearingOldJreContents)
  ; Try to remove individual files
  Delete "${LEADYA_SHARED_JRE_DIR}\*.*"
  ${LogLine} "(InstallJRE) Attempted to clear JRE folder contents"

  ; Show dialog with options
  ${LogLine} "(InstallJRE) Prompting user for action"
  MessageBox MB_YESNOCANCEL|MB_ICONEXCLAMATION "$(WARNING_jreRebootRequired)" IDYES RestartNow IDNO ManualRemove
  ${LogLine} "(InstallJRE) User cancelled installation"
  Abort

  RestartNow:
  ${LogLine} "(InstallJRE) User chose to reboot"
  Reboot

  ManualRemove:
  ${LogLine} "(InstallJRE) User chose to manually remove JRE folder"
  MessageBox MB_OK|MB_ICONINFORMATION "$(INFO_manualRemovalInstructions)"
  ${LogLine} "(InstallJRE) Waiting for user to manually remove JRE folder"
  MessageBox MB_OKCANCEL|MB_ICONQUESTION "$(QUESTION_jreRemovalComplete)" IDOK RetryRemoval IDCANCEL
  ${LogLine} "(InstallJRE) User cancelled after manual removal"
  Abort

  RetryRemoval:
  ${LogLine} "(InstallJRE) Retrying JRE folder removal"
  RMDir /r "${LEADYA_SHARED_JRE_DIR}"
  ${LogLine} "(InstallJRE) Retry RMDir /r command executed"

  ; Check if retry was successful
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\*.*" RemovalStillFailed
  ${LogLine} "(InstallJRE) Old JRE folder successfully removed after retry"
  Goto RemoveLegacyLocalJre

  RemovalStillFailed:
  ${LogLine} "(InstallJRE) Retry failed, still unable to remove JRE folder"
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(ERROR_couldNotRemoveJre)"
  ${LogLine} "(InstallJRE) User notified of persistent removal failure"
  Abort

  RemoveLegacyLocalJre:
  ${LogLine} "(InstallJRE) Removing legacy local JRE folder if it exists"
  ; The selected code directory can contain an unrelated or retained legacy runtime.

  CreateDirectory "${LEADYA_SHARED_JRE_PARENT}"
  ClearErrors
  Call AllocateLocalDownload
  IfErrors JreDownloadPreparationFailed
  ${StrRep} $JreArchivePath $LocalValidationOutput "$\r" ""
  ${StrRep} $JreArchivePath $JreArchivePath "$\n" ""

  DetailPrint $(LOG_installingJre)
  DetailPrint "$(LOG_downloadingJre)"
  ${LogLine} "(InstallJRE) Downloading fresh JRE package..."
  ;REPLACE WITH JRE FROM OUR SERVER!
  inetc::get ${url}/Java.zip "$JreArchivePath"
  ${LogLine} "(InstallJRE) Downloading JRE from ${url}/Java.zip"
  ;Check if download was successful
  Pop $0
  ${LogLine} "(InstallJRE) Downloading JRE response: $0"
  StrCmp $0 "OK" Install
  ${LogLine} "(InstallJRE) Downloading JRE failed"
  ${LogLine} "(InstallJRE) Error: $0"
  DetailPrint "$0" ;print error message to log
  !insertmacro ShowLocalStepFailure "LOCAL_JRE_DOWNLOAD" "JreDownload"
  Abort

  Install:
  ${LogLine} "(InstallJRE) JRE is downloaded"
  ;Check if JRE is installed
  ${LogLine} "(InstallJRE) Checking if JRE is installed"
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" Installed
  ${LogLine} "(InstallJRE) JRE is not installed"
  DetailPrint $(LOG_installingJre)
  ;Unzip into a stage folder, so a broken unpack can never look like a finished runtime
  StrCpy $LocalValidationMode "JreCreate"
  Call RequireTrustedLocalJre
  ${StrRep} $JreStagePath $LocalValidationOutput "$\r" ""
  ${StrRep} $JreStagePath $JreStagePath "$\n" ""
  System::Call 'kernel32::CreateFileW(w "$JreArchivePath", i 0x80000000, i 1, p 0, i 3, i 0, p 0) p .r9'
  StrCpy $JreArchiveHandle $9
  StrCmp $JreArchiveHandle -1 0 JreArchiveLocked
  !insertmacro ShowLocalStepFailure "LOCAL_JRE_ARCHIVE" "JreCreate"
  Abort
  JreArchiveLocked:
  ; The handle above denies writers, so the verified bytes are the bytes unpacked below.
  StrCpy $LocalValidationInput $JreArchivePath
  StrCpy $LocalValidationMode "JreVerify"
  Call ValidateLocalInstallation
  StrCmp $LocalValidationResult "0" JreArchiveVerified
  System::Call 'kernel32::CloseHandle(p $JreArchiveHandle)'
  !insertmacro ShowLocalStepFailure "LOCAL_JRE_ARCHIVE" "JreVerify"
  Abort
  JreArchiveVerified:
  nsisunz::UnzipToLog "$JreArchivePath" "$JreStagePath"
  ${LogLine} "(InstallJRE) Unzipping JRE"
  Pop $0
  System::Call 'kernel32::CloseHandle(p $JreArchiveHandle)'
  StrCmp $0 "success" JreUnpacked
    ${LogLine} "(InstallJRE) Unzipping JRE failed"
    ${LogLine} "(InstallJRE) Error: $0"
    DetailPrint "$0" ;print error message to log
    !insertmacro ShowLocalStepFailure "LOCAL_JRE_UNZIP" "JreCreate"
    Abort

  JreUnpacked:
  StrCpy $1 0
  JrePublishRetry:
  ClearErrors
  Rename "$JreStagePath\${LEADYA_BUNDLED_JRE_DIR}" "${LEADYA_SHARED_JRE_DIR}"
  IfErrors 0 JrePublished
  ; Another installer of this user may have finished first.
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" JrePublished
  ; A virus scanner can briefly hold the files that were just unpacked.
  IntOp $1 $1 + 1
  Sleep 500
  IntCmp $1 20 0 JrePublishRetry
  !insertmacro ShowLocalStepFailure "LOCAL_JRE_UNZIP" "JreCreate"
  Abort
  JrePublished:
  RMDir /r "$JreStagePath"

  Installed:
  StrCpy $LocalValidationMode "Jre"
  Call RequireTrustedLocalJre
  ${LogLine} "(InstallJRE) JRE is installed"

  IfFileExists "$JreArchivePath" 0 Finish
  ${LogLine} "(InstallJRE) Deleting JRE zip"
  ;Delete zip
  Delete "$JreArchivePath"
  Goto Finish
  JreDownloadPreparationFailed:
  ; AllocateLocalDownload left the validator's PackageTemp refusal code for support.
  Call ShowLocalInstallationFailure
  Abort
  Finish:
  ${LogLine} "(InstallJRE) Finished"
  
!macroend

Function WriteLineToFile
Exch $0
Exch
Exch $1
${GetTime} "" "L" $R0 $R1 $R2 $R3 $R4 $R5 $R6
StrCpy $1 "[$R4:$R5:$R6] $1"
FileOpen $0 $0 a
StrCmp $0 "" done
FileSeek $0 0 END
FileWrite $0 "$1$\r$\n"
FileClose $0
done:
Pop $1
Pop $0
FunctionEnd
