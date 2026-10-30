@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnostics.ps1"
set "ZH_EXIT=%errorlevel%"
exit /b %ZH_EXIT%
