@echo off
REM Wrapper for delete-secret.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\delete-secret.ps1" %*
