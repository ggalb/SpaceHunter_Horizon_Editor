@echo off
REM Launches the GS Server bridge (STA, needed for ASCOM COM) and serves the
REM Horizon Editor at http://localhost:5555 . Double-click to run.
REM For testing against a different driver, edit -ProgId below.
powershell -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0gss-bridge.ps1" -Port 5555
echo.
echo Bridge stopped. Press any key to close.
pause >nul
