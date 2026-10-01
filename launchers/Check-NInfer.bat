@echo off
setlocal
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\install\verify-installation.ps1" -Full
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
