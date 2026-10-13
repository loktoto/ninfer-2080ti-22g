@echo off
setlocal
title Install NInfer SM75
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ninfer-sm75.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" pause
exit /b %RC%
