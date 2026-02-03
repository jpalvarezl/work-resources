@echo off
REM Wrapper for update-secret.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\update-secret.ps1" %*
