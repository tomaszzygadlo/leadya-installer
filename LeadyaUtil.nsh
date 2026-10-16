;Includes
;--------------------------------
!include "MUI2.nsh"
!include 'LogicLib.nsh'
!include "WinMessages.nsh"
!include "FileFunc.nsh"
!include nsDialogs.nsh
!include Util.nsh

!define LEADYA_BUNDLED_JRE_DIR "jdk-17.0.9+9-jre"
!define LEADYA_SHARED_JRE_PARENT "$PROGRAMFILES64\Java"
!define LEADYA_SHARED_JRE_DIR "${LEADYA_SHARED_JRE_PARENT}\${LEADYA_BUNDLED_JRE_DIR}"
!ifndef LEADYA_INSTALL_DOWNLOAD_DIR
  !define LEADYA_INSTALL_DOWNLOAD_DIR "$INSTDIR"
!endif
Var JreArchiveHandle
Var JreArchivePath

!macro _StrContainsConstructor OUT NEEDLE HAYSTACK
  Push `${HAYSTACK}`
  Push `${NEEDLE}`
  Call StrContains
  Pop `${OUT}`
!macroend
!define StrContains '!insertmacro "_StrContainsConstructor"'

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
  !ifdef LEADYA_TRUSTED_DOWNLOADS
    StrCpy $LocalValidationMode "JrePrepare"
    Call RequireTrustedLocalJre
  !endif
  ; A working shared runtime must remain available to other installed clients.
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" 0 CheckOldJre
  !ifdef LEADYA_TRUSTED_DOWNLOADS
    ; LOCAL uses the pinned helper's isolated child environment. A failed probe never deletes a shared JRE.
    StrCpy $LocalValidationMode "JreProbe"
    Call RequireTrustedLocalJre
    Goto Finish
  !else
  nsExec::ExecToStack /TIMEOUT=15000 '"${LEADYA_SHARED_JRE_DIR}\bin\java.exe" -version'
  Pop $0
  Pop $1
  StrCmp $0 "0" Finish
  !endif
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
  !ifdef LEADYA_TRUSTED_DOWNLOADS
    Call AllocateLocalDownload
    IfErrors JreDownloadPreparationFailed
    ${StrRep} $JreArchivePath $LocalValidationOutput "$\r" ""
    ${StrRep} $JreArchivePath $JreArchivePath "$\n" ""
  !else
    GetTempFileName $JreArchivePath "${LEADYA_INSTALL_DOWNLOAD_DIR}"
    IfErrors JreDownloadPreparationFailed
  !endif

  DetailPrint $(LOG_installingJre)
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
  MessageBox MB_OK|MB_ICONEXCLAMATION $(ERROR_somethingWentWrong) /SD IDOK
  Abort

  Install:
  ${LogLine} "(InstallJRE) JRE is downloaded"
  ;Check if JRE is installed
  ${LogLine} "(InstallJRE) Checking if JRE is installed"
  IfFileExists "${LEADYA_SHARED_JRE_DIR}\bin\java.exe" Installed
  ${LogLine} "(InstallJRE) JRE is not installed"
  DetailPrint $(LOG_installingJre)
  ;Unzip
  !ifdef LEADYA_TRUSTED_DOWNLOADS
    StrCpy $LocalValidationMode "JreCreate"
    Call RequireTrustedLocalJre
  !endif
  System::Call 'kernel32::CreateFileW(w "$JreArchivePath", i 0x80000000, i 1, p 0, i 3, i 0, p 0) p .r9'
  StrCpy $JreArchiveHandle $9
  StrCmp $JreArchiveHandle -1 0 JreArchiveLocked
  MessageBox MB_OK $(ERROR_somethingWentWrong) /SD IDOK
  Abort
  JreArchiveLocked:
  nsisunz::UnzipToLog "$JreArchivePath" "${LEADYA_SHARED_JRE_PARENT}"
  ${LogLine} "(InstallJRE) Unzipping JRE"
  Pop $0
  System::Call 'kernel32::CloseHandle(p $JreArchiveHandle)'
  StrCmp $0 "success" Installed
    ${LogLine} "(InstallJRE) Unzipping JRE failed"
    ${LogLine} "(InstallJRE) Error: $0"
    DetailPrint "$0" ;print error message to log
    MessageBox MB_OK $(ERROR_somethingWentWrong) /SD IDOK
    Abort

  Installed:
  !ifdef LEADYA_TRUSTED_DOWNLOADS
    StrCpy $LocalValidationMode "Jre"
    Call RequireTrustedLocalJre
  !endif
  ${LogLine} "(InstallJRE) JRE is installed"

  IfFileExists "$JreArchivePath" 0 Finish
  ${LogLine} "(InstallJRE) Deleting JRE zip"
  ;Delete zip
  Delete "$JreArchivePath"
  Goto Finish
  JreDownloadPreparationFailed:
  MessageBox MB_OK $(ERROR_somethingWentWrong) /SD IDOK
  Abort
  Finish:
  ${LogLine} "(InstallJRE) Finished"
  
!macroend

Var STR_HAYSTACK
Var STR_NEEDLE
Var STR_CONTAINS_VAR_1
Var STR_CONTAINS_VAR_2
Var STR_CONTAINS_VAR_3
Var STR_CONTAINS_VAR_4
Var STR_RETURN_VAR
 
Function StrContains
  Exch $STR_NEEDLE
  Exch 1
  Exch $STR_HAYSTACK
  ; Uncomment to debug
  ; MessageBox MB_OK 'STR_NEEDLE = $STR_NEEDLE STR_HAYSTACK = $STR_HAYSTACK '
    StrCpy $STR_RETURN_VAR ""
    StrCpy $STR_CONTAINS_VAR_1 -1
    StrLen $STR_CONTAINS_VAR_2 $STR_NEEDLE
    StrLen $STR_CONTAINS_VAR_4 $STR_HAYSTACK
    loop:
      IntOp $STR_CONTAINS_VAR_1 $STR_CONTAINS_VAR_1 + 1
      StrCpy $STR_CONTAINS_VAR_3 $STR_HAYSTACK $STR_CONTAINS_VAR_2 $STR_CONTAINS_VAR_1
      StrCmp $STR_CONTAINS_VAR_3 $STR_NEEDLE found
      StrCmp $STR_CONTAINS_VAR_1 $STR_CONTAINS_VAR_4 done
      Goto loop
    found:
      StrCpy $STR_RETURN_VAR $STR_NEEDLE
      Goto done
    done:
   Pop $STR_NEEDLE ;Prevent "invalid opcode" errors and keep the
   Exch $STR_RETURN_VAR  
FunctionEnd

Function DisableNextButton
  GetDlgItem $0 $HWNDPARENT 1
  EnableWindow $0 0
FunctionEnd

Function EnableNextButton
  GetDlgItem $0 $HWNDPARENT 1
  EnableWindow $0 1
FunctionEnd

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

Function RelGotoPage
  IntCmp $R9 0 0 Move Move
    StrCmp $R9 "X" 0 Move
      StrCpy $R9 "120"
 
  Move:
  SendMessage $HWNDPARENT "0x408" "$R9" ""
FunctionEnd


Function openLinkNewWindow
  Push $3
  Exch
  Push $2
  Exch
  Push $1
  Exch
  Push $0
  Exch
 
  ReadRegStr $0 HKCR "http\shell\open\command" ""
# Get browser path
    DetailPrint $0
  StrCpy $2 '"'
  StrCpy $1 $0 1
  StrCmp $1 $2 +2 # if path is not enclosed in " look for space as final char
    StrCpy $2 ' '
  StrCpy $3 1
  loop:
    StrCpy $1 $0 1 $3
    DetailPrint $1
    StrCmp $1 $2 found
    StrCmp $1 "" found
    IntOp $3 $3 + 1
    Goto loop
 
  found:
    StrCpy $1 $0 $3
    StrCmp $2 " " +2
      StrCpy $1 '$1"'
 
  Pop $0
  Exec '$1 $0'
  Pop $0
  Pop $1
  Pop $2
  Pop $3
FunctionEnd
 
!macro _OpenURL URL
Push "${URL}"
Call openLinkNewWindow
!macroend
 
!define OpenURL '!insertmacro "_OpenURL"'


var Email
var Password

Function Login
  Call DisableNextButton
  ${LogLine} "(Login) Disabling next button"
  ${LogLine} "(Login) Email: $Email"
  StrLen $0 $Password
  ${LogLine} "(Login) Password: *** (length: $0)"

  ; Proper URL encoding for POST data
  ${LogLine} "(Login) Encoding credentials for POST request"

  ; URL encode email for POST
  StrCpy $EmailEncoded $Email
  ${StrRep} $EmailEncoded $EmailEncoded "%" "%25"
  ${StrRep} $EmailEncoded $EmailEncoded "+" "%2B"
  ${StrRep} $EmailEncoded $EmailEncoded "&" "%26"
  ${StrRep} $EmailEncoded $EmailEncoded "=" "%3D"
  ${StrRep} $EmailEncoded $EmailEncoded " " "%20"
  ${StrRep} $EmailEncoded $EmailEncoded "@" "%40"
  ${StrRep} $EmailEncoded $EmailEncoded "#" "%23"
  ${StrRep} $EmailEncoded $EmailEncoded "?" "%3F"
  ${StrRep} $EmailEncoded $EmailEncoded "<" "%3C"
  ${StrRep} $EmailEncoded $EmailEncoded ">" "%3E"
  ${StrRep} $EmailEncoded $EmailEncoded "$\"" "%22"
  ${StrRep} $EmailEncoded $EmailEncoded "'" "%27"

  ; URL encode password for POST
  StrCpy $PasswordEncoded $Password
  ${StrRep} $PasswordEncoded $PasswordEncoded "%" "%25"
  ${StrRep} $PasswordEncoded $PasswordEncoded "+" "%2B"
  ${StrRep} $PasswordEncoded $PasswordEncoded "&" "%26"
  ${StrRep} $PasswordEncoded $PasswordEncoded "=" "%3D"
  ${StrRep} $PasswordEncoded $PasswordEncoded " " "%20"
  ${StrRep} $PasswordEncoded $PasswordEncoded "#" "%23"
  ${StrRep} $PasswordEncoded $PasswordEncoded "?" "%3F"
  ${StrRep} $PasswordEncoded $PasswordEncoded "*" "%2A"
  ${StrRep} $PasswordEncoded $PasswordEncoded "<" "%3C"
  ${StrRep} $PasswordEncoded $PasswordEncoded ">" "%3E"
  ${StrRep} $PasswordEncoded $PasswordEncoded "$\"" "%22"
  ${StrRep} $PasswordEncoded $PasswordEncoded "'" "%27"
  ${StrRep} $PasswordEncoded $PasswordEncoded "{" "%7B"
  ${StrRep} $PasswordEncoded $PasswordEncoded "}" "%7D"
  ${StrRep} $PasswordEncoded $PasswordEncoded "[" "%5B"
  ${StrRep} $PasswordEncoded $PasswordEncoded "]" "%5D"
  ${StrRep} $PasswordEncoded $PasswordEncoded "\" "%5C"
  ${StrRep} $PasswordEncoded $PasswordEncoded "/" "%2F"
  ${StrRep} $PasswordEncoded $PasswordEncoded ":" "%3A"
  ${StrRep} $PasswordEncoded $PasswordEncoded ";" "%3B"
  ${StrRep} $PasswordEncoded $PasswordEncoded "," "%2C"
  ${StrRep} $PasswordEncoded $PasswordEncoded "." "%2E"
  ${StrRep} $PasswordEncoded $PasswordEncoded "~" "%7E"
  ${StrRep} $PasswordEncoded $PasswordEncoded "!" "%21"
  ${StrRep} $PasswordEncoded $PasswordEncoded "$$" "%24"
  ${StrRep} $PasswordEncoded $PasswordEncoded "^" "%5E"
  ${StrRep} $PasswordEncoded $PasswordEncoded "(" "%28"
  ${StrRep} $PasswordEncoded $PasswordEncoded ")" "%29"

  ${LogLine} "(Login) Credentials encoded for POST request"

  ; Use only the secure /installer/login endpoint
  ${LogLine} "(Login) Attempting secure login via /installer/login"
  ${LogLine} "(Login) Target URL: ${url}/installer/login"

  inetc::post "email=$EmailEncoded&password=$PasswordEncoded" "${url}/installer/login" "$INSTDIR\temp.html" /END
  ${LogLine} "(Login) POST request completed"
  Pop $0
  ${LogLine} "(Login) POST request response code: $0"

  ; Check if endpoint works
  StrCmp $0 "OK" SecureEndpointOk

  ; Login failed - show error and abort
  ${LogLine} "(Login) Login failed with response: $0"
  ${LogLine} "(Login) HTTP Error Details: $0"
  ${LogLine} "(Login) Possible causes:"
  ${LogLine} "(Login) 1. Wrong credentials"
  ${LogLine} "(Login) 2. Endpoint not available on ${url}"
  ${LogLine} "(Login) 3. Network connectivity issues"
  ${LogLine} "(Login) 4. Server is down or overloaded"
  ${LogLine} "(Login) 5. SSL/TLS certificate problems"
  MessageBox MB_OK|MB_ICONEXCLAMATION "Login Error: $0$\r$\n$\r$\nDetails in log: $INSTDIR\$currentLogFileName$\r$\n$\r$\nPlease check:$\r$\n- Your credentials$\r$\n- Internet connection$\r$\n- Server status: ${url}" /SD IDOK
  Call EnableNextButton
  ${LogLine} "(Login) Enabling next button after error"
  Abort

  SecureEndpointOk:
  Pop $0
  ${LogLine} "(Login) Secure endpoint successful, checking response"
  Call ReadInstallerLoginResponse
  ${LogLine} "(Login) Secure response parsing result: $2"
  StrCmp $2 "" LoginOk
  ${LogLine} "(Login) Secure login failed - wrong credentials"
  MessageBox MB_OK|MB_ICONEXCLAMATION "$(ERROR_wrongCredentials)$\r$\n$\r$\nUsing secure login method.$\r$\nCheck log: $INSTDIR\$currentLogFileName" /SD IDOK
  Call EnableNextButton
  ${LogLine} "(Login) Enabling next button"
  Abort

  LoginOk:
  ${LogLine} "(Login) Login successful!"

  ; Credentials are already encoded and ready for bot.properties download
  ${LogLine} "(Login) Encoded credentials prepared for bot.properties download"

  Call EnableNextButton
  ${LogLine} "(Login) Enabling next button"
FunctionEnd


Function ReadInstallerLoginResponse
  ClearErrors
  FileOpen $0 "$INSTDIR\temp.html" r
  ${LogLine} "(ReadInstallerLoginResponse) Opening file $INSTDIR\temp.html"

  ; Read the entire response
  FileRead $0 $1
  ${LogLine} "(ReadInstallerLoginResponse) Response content: $1"

  ; Check if response contains "Success"
  ${StrContains} $2 "Success:" $1
  StrCmp $2 "" CheckError
  ; Success found - clear $2 to indicate success
  StrCpy $2 ""
  ${LogLine} "(ReadInstallerLoginResponse) Login successful"
  Goto CloseFile

  CheckError:
  ; Check if response contains "Error"
  ${StrContains} $2 "Error:" $1
  StrCmp $2 "" UnknownResponse
  ; Error found - set $2 to non-empty to indicate failure
  StrCpy $2 "ERROR"
  ${LogLine} "(ReadInstallerLoginResponse) Login failed with error"
  Goto CloseFile

  UnknownResponse:
  ; Unknown response - assume failure
  StrCpy $2 "UNKNOWN"
  ${LogLine} "(ReadInstallerLoginResponse) Unknown response format"

  CloseFile:
  FileClose $0
  ${LogLine} "(ReadInstallerLoginResponse) Closing file $INSTDIR\temp.html"
  Delete "$INSTDIR\temp.html"
FunctionEnd
