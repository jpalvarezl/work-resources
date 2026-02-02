@echo off
REM Wrapper for migrate-secrets.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\migrate-secrets.ps1" %*
