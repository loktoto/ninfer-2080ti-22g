@echo off
setlocal
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\install\first-run-wizard.ps1"
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
