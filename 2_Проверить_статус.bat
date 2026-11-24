@echo off
setlocal
title Copilot Autostart Killer - Status - By LowiKLive
rem ==========================================================================
rem  Copilot Autostart Killer  -  CHECK STATUS (read only, no changes)
rem  By LowiKLive
rem ==========================================================================

echo.
echo   Copilot Autostart Killer  -  By LowiKLive
if not exist "%~dp0Check-CopilotAutostart.ps1" goto missing_ps1
echo   Checking status...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-CopilotAutostart.ps1" -NoPause
if errorlevel 1 echo.& echo   [!] Something went wrong - read the messages above.& echo.

echo.
echo   Press any key to close.
pause >nul
exit /b 0

:missing_ps1
echo.
echo   [!] File "Check-CopilotAutostart.ps1" was not found next to this .bat.
echo   The .bat is only a launcher - the real logic is in the .ps1 file.
echo   Unpack the WHOLE folder and keep all files together.
echo.
pause
exit /b 1
