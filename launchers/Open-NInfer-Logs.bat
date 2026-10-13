@echo off
setlocal
cd /d "%~dp0.."
if not exist "%~dp0..\logs" mkdir "%~dp0..\logs"
start "" explorer.exe "%~dp0..\logs"
