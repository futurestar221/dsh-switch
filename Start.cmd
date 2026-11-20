@echo off
setlocal
if exist "%~dp0app\dsh-switch.exe" (
  start "" "%~dp0app\dsh-switch.exe"
) else (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0web\start.ps1" -NoWindow
)
endlocal
