"""Exercise the real directory page in an ordinary, self-driving NSIS fixture."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1]
if not (SOURCE / "Leadya.nsi").is_file():
    SOURCE = Path(__file__).resolve().parent
NSIS = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "NSIS/makensis.exe"


def capture_fixture_window(pid, output):
    """Print only this fixture's own window; never capture the user's desktop."""
    import ctypes as c
    from ctypes import wintypes as w
    import struct
    from PIL import Image
    user, gdi = c.windll.user32, c.windll.gdi32
    callback_type = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    user.EnumWindows.argtypes = [callback_type, w.LPARAM]
    user.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
    user.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
    user.GetWindowDC.argtypes, user.GetWindowDC.restype = [w.HWND], w.HDC
    user.PrintWindow.argtypes = [w.HWND, w.HDC, w.UINT]
    user.ReleaseDC.argtypes = [w.HWND, w.HDC]
    for name, args, result in [
        ("CreateCompatibleDC", [w.HDC], w.HDC),
        ("CreateCompatibleBitmap", [w.HDC, c.c_int, c.c_int], w.HBITMAP),
        ("SelectObject", [w.HDC, w.HGDIOBJ], w.HGDIOBJ),
        ("DeleteObject", [w.HGDIOBJ], w.BOOL),
        ("DeleteDC", [w.HDC], w.BOOL),
        ("GetDIBits", [w.HDC, w.HBITMAP, w.UINT, w.UINT, c.c_void_p, c.c_void_p, w.UINT], c.c_int),
    ]:
        function = getattr(gdi, name)
        function.argtypes, function.restype = args, result
    windows = []
    @callback_type
    def visit(hwnd, _):
        owner = w.DWORD()
        user.GetWindowThreadProcessId(hwnd, c.byref(owner))
        if owner.value == pid and user.IsWindowVisible(hwnd):
            windows.append(hwnd)
        return True
    deadline = time.monotonic() + 3
    while not windows and time.monotonic() < deadline:
        user.EnumWindows(visit, 0)
        time.sleep(0.05)
    if not windows:
        raise AssertionError("Owned fixture window was not found")
    hwnd = windows[0]
    rect = w.RECT()
    user.GetWindowRect(hwnd, c.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    dc = user.GetWindowDC(hwnd)
    memory = gdi.CreateCompatibleDC(dc)
    bitmap = gdi.CreateCompatibleBitmap(dc, width, height)
    old = gdi.SelectObject(memory, bitmap)
    try:
        if not user.PrintWindow(hwnd, memory, 2):
            raise AssertionError("Owned fixture PrintWindow failed")
        gdi.SelectObject(memory, old)
        pixels = c.create_string_buffer(width * height * 4)
        header = c.create_string_buffer(struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 32, 0, len(pixels), 0, 0, 0, 0))
        if gdi.GetDIBits(memory, bitmap, 0, height, pixels, header, 0) != height:
            raise AssertionError("Owned fixture pixels were not read")
        Image.frombytes("RGB", (width, height), pixels.raw, "raw", "BGRX").save(output)
    finally:
        gdi.SelectObject(memory, old)
        gdi.DeleteObject(bitmap)
        gdi.DeleteDC(memory)
        user.ReleaseDC(hwnd, dc)


@unittest.skipUnless(os.name == "nt", "Native Windows NSIS UI is required")
class InstallerDirectoryTest(unittest.TestCase):
    def test_real_button_reset_and_back_navigation_without_installing(self):
        source = (SOURCE / "Leadya.nsi").read_text(encoding="utf-8-sig")
        page = source.split("; BEGIN LOCAL DIRECTORY PAGE", 1)[1].split("; END LOCAL DIRECTORY PAGE", 1)[0]
        if os.environ.get("LEADYA_TEST_DISABLE_DIRECTORY_RESET"):
            # Causal mutant: retain the real button/event but remove its reset operation.
            page = page.replace('  StrCpy $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}"\n'
                                '  ${NSD_SetText} $LocalDirectoryPath "$INSTDIR"', '')
        # Replace only the native folder-picker boundary to exercise its cancellation branch.
        page = page.replace('nsDialogs::SelectFolderDialog "$(^DirBrowseText)" "$INSTDIR"', 'Push "error"')
        page = page.replace("  nsDialogs::Show", "  ${NSD_CreateTimer} DriveDirectoryTest 700\n  nsDialogs::Show", 1)
        with tempfile.TemporaryDirectory(prefix="leadya-directory-owned-", dir=Path.home() / "Downloads") as folder:
            base = Path(folder)
            exe = base / "directory.exe"
            report = base / "result.txt"
            script = r'''
Unicode true
Name "LeadYa [TEST]"
RequestExecutionLevel user
!include MUI2.nsh
!include nsDialogs.nsh
!include FileFunc.nsh
!define MUI_DIRECTORYPAGE
@DIRECTORY_CONSTANTS@
Var LocalDirectoryDialog
Var LocalDirectoryPath
Var LocalDirectoryRestore
Var LocalDirectorySpace
Var LocalDirectorySpaceReady
Var phase
Var leaveCount
Page custom ShowLocalDirectoryPage LeaveLocalDirectoryPage
Page custom ShowAfterDirectory
!insertmacro MUI_LANGUAGE "Polish"
LangString RestoreDefaultLocation ${LANG_POLISH} "Przywróć domyślną lokalizację"
Function .onInit
  StrCpy $phase "0"
  StrCpy $leaveCount "0"
  StrCpy $INSTDIR "C:\wybrany folder ź ! & %"
FunctionEnd
Function RequireLocalDestination
  ; External policy boundary: production Leave must still call it after reading the edit.
  StrCmp $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}" +2
  System::Call 'kernel32::ExitProcess(i 94)'
  IntOp $leaveCount $leaveCount + 1
FunctionEnd
Function DriveDirectoryTest
  ${NSD_KillTimer} DriveDirectoryTest
  StrCmp $phase "0" FirstVisit SecondVisit
  FirstVisit:
  StrCmp $INSTDIR "C:\wybrany folder ź ! & %" +2
  System::Call 'kernel32::ExitProcess(i 91)'
  Goto Reset
  SecondVisit:
  StrCmp $INSTDIR "${LEADYA_DEFAULT_INSTALL_DIR}" +2
  System::Call 'kernel32::ExitProcess(i 92)'
  ${NSD_SetText} $LocalDirectoryPath ""
  GetDlgItem $0 $HWNDPARENT 1
  System::Call 'user32::IsWindowEnabled(p r0) i .r1'
  StrCmp $1 "0" +2
  System::Call 'kernel32::ExitProcess(i 93)'
  ${NSD_SetText} $LocalDirectoryPath "@MISSING@"
  StrCmp $LocalDirectorySpaceReady "1" +2
  System::Call 'kernel32::ExitProcess(i 86)'
  ${NSD_SetText} $LocalDirectoryPath "//server/share"
  StrCmp $LocalDirectorySpaceReady "0" +2
  System::Call 'kernel32::ExitProcess(i 87)'
  ${NSD_SetText} $LocalDirectoryPath "C:relative"
  StrCmp $LocalDirectorySpaceReady "0" +2
  System::Call 'kernel32::ExitProcess(i 88)'
  ${NSD_SetText} $LocalDirectoryPath "C:\inny folder ż"
  Push 0
  Call BrowseLocalDirectory
  ${NSD_GetText} $LocalDirectoryPath $1
  StrCmp $1 "C:\inny folder ż" +2
  System::Call 'kernel32::ExitProcess(i 95)'
  Reset:
  SendMessage $LocalDirectoryRestore ${BM_CLICK} 0 0
  SendMessage $LocalDirectoryRestore ${BM_CLICK} 0 0
  ${NSD_GetText} $LocalDirectoryPath $1
  StrCmp $1 "${LEADYA_DEFAULT_INSTALL_DIR}" +2
  System::Call 'kernel32::ExitProcess(i 96)'
  StrCmp $INSTDIR $1 +2
  System::Call 'kernel32::ExitProcess(i 97)'
  System::Call 'user32::GetFocus() p .r0'
  StrCmp $0 $LocalDirectoryPath +2
  System::Call 'kernel32::ExitProcess(i 98)'
  GetDlgItem $0 $HWNDPARENT 1
  System::Call 'user32::IsWindowEnabled(p r0) i .r1'
  StrCmp $1 "1" +2
  System::Call 'kernel32::ExitProcess(i 99)'
  SendMessage $HWNDPARENT ${WM_COMMAND} 1 0
FunctionEnd
Function ShowAfterDirectory
  StrCmp $phase "0" GoBack FinishTest
  GoBack:
  StrCpy $phase "1"
  nsDialogs::Create 1018
  Pop $0
  ${NSD_CreateTimer} ReturnToDirectory 50
  nsDialogs::Show
  Return
  FinishTest:
  StrCmp $leaveCount "2" +2
  System::Call 'kernel32::ExitProcess(i 90)'
  FileOpen $0 "@REPORT@" w
  FileWrite $0 "PASS: actual reset button twice per visit, Unicode custom path, edit/state/focus, empty-path Next gate, picker cancellation, Back/Next, policy leave; no install"
  FileClose $0
  SetErrorLevel 0
  Quit
FunctionEnd
Function ReturnToDirectory
  ${NSD_KillTimer} ReturnToDirectory
  SendMessage $HWNDPARENT ${WM_COMMAND} 3 0
FunctionEnd
Section
  ; This fixture must quit before any installation section can execute.
  SetErrorLevel 89
SectionEnd
'''
            constants = "\n".join(re.findall(r"^!define(?: /math)? LEADYA_(?:DEFAULT_INSTALL_DIR|LOCAL_INSTALL_SIZE_\w+) .+$", source, re.MULTILINE))
            script = script.replace("@REPORT@", str(report)).replace("@DIRECTORY_CONSTANTS@", constants).replace("@MISSING@", base.as_posix() + "/not-created/child") + page
            nsi = base / "directory.nsi"
            nsi.write_text('OutFile "' + str(exe) + '"\n' + script, encoding="utf-8-sig")
            compiled = subprocess.run([str(NSIS), "/V2", str(nsi)], capture_output=True, text=True, timeout=30)
            self.assertEqual(0, compiled.returncode, compiled.stdout + compiled.stderr)
            with subprocess.Popen([str(exe)], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                try:
                    screenshot = os.environ.get("LEADYA_DIRECTORY_SCREENSHOT")
                    if screenshot:
                        capture_fixture_window(process.pid, screenshot)
                    process.communicate(timeout=30)
                except BaseException:
                    process.kill()
                    process.communicate()
                    raise
                self.assertEqual(0, process.returncode, "Native fixture exit code identifies the failed UI assertion")
            self.assertTrue(report.read_text().startswith("PASS:"))


if __name__ == "__main__":
    unittest.main()
