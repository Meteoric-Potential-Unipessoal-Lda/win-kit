@echo off
setlocal
cd /d "%~dp0"
title win-kit
net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  win-kit: requesting administrator rights ^(UAC^)...
  echo  AnyDesk shows a black screen? Ask the client to press "Yes",
  echo  or in AnyDesk: Actions - Request elevation.
  echo.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File" >nul 2>&1
rem window (GUI) - the console hides itself once the window is open; if it cannot open - console menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0winkit.ps1" -Mode gui
if errorlevel 5 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0winkit.ps1"
  if errorlevel 1 pause
)
