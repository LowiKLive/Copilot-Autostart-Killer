@echo off
setlocal
title Copilot Autostart Killer - Restore - By LowiKLive
rem ==========================================================================
rem  Copilot Autostart Killer  -  RESTORE (undo all changes)
rem  By LowiKLive
rem ==========================================================================

rem fltmc is used instead of "net session" because it does not depend on
rem the Server (LanmanServer) service, which is often disabled on tuned PCs.
fltmc >nul 2>&1
if %errorlevel% equ 0 goto run_admin

rem Do not loop forever if elevation never gives us admin rights.
if not defined COPILOT_KIT_ELEVATED goto try_elevate
echo.
echo   [!] Could not get administrator rights.
echo   Right-click this file and choose "Run as administrator".
pause
exit /b 1

:try_elevate
echo.
echo   Copilot Autostart Killer  -  By LowiKLive
echo.
echo   Requesting administrator rights. Click YES in the UAC window...
echo   IMPORTANT: use YOUR OWN account, not another admin's credentials.
set "COPILOT_KIT_ELEVATED=1"
set "COPILOT_KIT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:COPILOT_KIT_SELF -Verb RunAs"
exit /b

:run_admin
echo.
echo   Copilot Autostart Killer  -  By LowiKLive
if not exist "%~dp0Restore-CopilotAutostart.ps1" goto missing_ps1
echo   Restoring Copilot autostart to its original state...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-CopilotAutostart.ps1" -NoPause
if errorlevel 1 echo.& echo   [!] Something went wrong - read the messages above.& echo.

echo.
echo   Press any key to close.
pause >nul
exit /b 0

:missing_ps1
echo.
echo   [!] File "Restore-CopilotAutostart.ps1" was not found next to this .bat.
echo   The .bat is only a launcher - the real logic is in the .ps1 file.
echo   Unpack the WHOLE folder and keep all files together.
echo.
pause
exit /b 1
