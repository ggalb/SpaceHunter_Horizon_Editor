@echo off
REM Launches the mount bridge (STA, needed for ASCOM COM) and serves the
REM Horizon Editor at http://localhost:5555 . Double-click to run.
REM On start it opens the ASCOM Chooser so you can pick ANY mount (GS Server,
REM ZWO AM, iOptron, EQMOD, simulator, ...). To skip the dialog, add e.g.
REM   -ProgId ASCOM.Simulator.Telescope
powershell -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0mount-bridge.ps1" -Port 5555
echo.
echo Bridge stopped. Press any key to close.
pause >nul
