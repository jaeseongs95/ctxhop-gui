@echo off
setlocal
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "%~dp0GUI.ps1"
