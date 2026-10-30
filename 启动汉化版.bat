@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo   Codex Desktop Zh-CN - Launch
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-CodexZh.ps1"
set "ZH_EXIT=%errorlevel%"
if not "%ZH_EXIT%"=="0" (
  echo.
  echo Exit code: %ZH_EXIT%
  echo Logs: %LOCALAPPDATA%\CodexZhCn\logs
)
exit /b %ZH_EXIT%
