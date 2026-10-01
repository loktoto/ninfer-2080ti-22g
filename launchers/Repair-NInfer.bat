@echo off
setlocal
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\install\repair-ninfer-sm75.ps1" -Restart
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
