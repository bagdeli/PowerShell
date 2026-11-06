@echo off
setlocal
set "APP=%~dp0DNS-Studio.ps1"
if not exist "%APP%" (
  echo DNS-Studio.ps1 was not found next to this launcher.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%APP%"
if errorlevel 1 (
  echo.
  echo DNS Studio could not start. Please read the error above.
  pause
)
