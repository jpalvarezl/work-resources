@echo off
REM Wrapper for add-user.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\add-user.ps1" %*
