@echo off
setlocal
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\manage-installed-server.ps1" -Action Start -Mode Base
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
