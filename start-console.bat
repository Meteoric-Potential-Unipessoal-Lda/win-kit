@echo off
setlocal
cd /d "%~dp0"
title win-kit (console)
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0winkit.ps1"
if errorlevel 1 pause
