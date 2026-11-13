@echo off
rem Builds dist\Uma2Roblox.exe (needs Python 3.10+ from python.org, with tcl/tk)
cd /d "%~dp0"
py -3 -m pip install --upgrade -r requirements.txt pyinstaller || goto :err
py -3 -m PyInstaller --noconfirm --onefile --windowed --collect-all UnityPy --collect-all apsw --add-data "roblox/Uma2Roblox.plugin.lua;roblox" --name Uma2Roblox uma2roblox.py || goto :err
copy /y dist\Uma2Roblox.exe Uma2Roblox.exe >nul
echo.
echo Built: %~dp0Uma2Roblox.exe
pause
exit /b 0
:err
echo Build failed.
pause
exit /b 1
