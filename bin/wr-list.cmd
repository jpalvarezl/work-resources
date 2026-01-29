@echo off
REM Wrapper for list-secrets.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\list-secrets.ps1" %*
