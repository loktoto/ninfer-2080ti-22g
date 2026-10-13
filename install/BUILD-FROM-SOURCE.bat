@echo off
setlocal
title NInfer SM75 - Developer Bootstrap
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-developer-windows-sm75.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Developer bootstrap failed with exit code %RC%.
if "%RC%"=="0" echo Developer bootstrap and production build completed.
pause
exit /b %RC%
