@echo off
setlocal
title NInfer RTX 2080 Ti 22GB - Installer
cd /d "%~dp0"
if exist "%~dp0install\install-ninfer-sm75.ps1" (
  set "INSTALLER=%~dp0install\install-ninfer-sm75.ps1"
) else (
  set "INSTALLER=%~dp0install-ninfer-sm75.ps1"
)
if not exist "%INSTALLER%" (
  echo ERROR: install-ninfer-sm75.ps1 was not found.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Installation failed with exit code %RC%.
if "%RC%"=="0" echo Installation completed successfully.
pause
exit /b %RC%
