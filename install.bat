@echo off
rem Installs the Roblox Studio plugin. Build the app itself with build_exe.bat (or start it with run.bat).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
