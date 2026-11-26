' Launch-AIHub.vbs - kept only so an older shortcut or pinned item still works.
' It no longer starts PowerShell itself: it hands straight to AIHub.exe, which
' is a GUI-subsystem program. That program starts PowerShell with
' CREATE_NO_WINDOW, so no console window is ever created, and there is nothing
' to close by accident.
'
' WScript.Shell.Run with a window style of 0 only *hides* the console that
' Windows already made - the console still exists, can still appear, and takes
' the hub with it when closed. That is why this file is no longer the entry
' point.
Option Explicit
Dim fso, sh, here, exe
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
exe = here & "\AIHub.exe"

If fso.FileExists(exe) Then
  sh.Run Chr(34) & exe & Chr(34), 1, False
Else
  ' Fallback only: no AIHub.exe next to this script.
  sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & here & "\Start-AIHub.ps1""", 0, False
End If
