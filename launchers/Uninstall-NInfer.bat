@echo off
setlocal
title Uninstall NInfer SM75
cd /d "%~dp0.."
echo This removes the NInfer runtime but keeps the large model by default.
echo.
set /p CONFIRM=Type YES to continue: 
if /I not "%CONFIRM%"=="YES" exit /b 0
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\install\uninstall-ninfer-sm75.ps1"
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
