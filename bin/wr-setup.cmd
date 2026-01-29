@echo off
REM Wrapper for setup.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\setup.ps1" %*
