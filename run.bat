@echo off
rem Runs Uma2Roblox without building an exe
cd /d "%~dp0"
py -3 -m pip install -q -r requirements.txt
start "" pyw -3 uma2roblox.py
