' Starts Pulse without a visible console window (real tray behaviour).
' Double-click to run. To quit: right-click the tray icon -> Quit.
Option Explicit
Dim sh, dir, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "pwsh -NoProfile -WindowStyle Hidden -File """ & dir & "Pulse.ps1"""
' 0 = hide window, False = don't wait for exit
sh.Run cmd, 0, False
