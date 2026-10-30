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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0winkit.ps1"
if errorlevel 1 pause
