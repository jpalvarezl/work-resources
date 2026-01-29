@echo off
REM Wrapper for save-secret.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\save-secret.ps1" %*
