@echo off
REM Wrapper for clear-env.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\clear-env.ps1" %*
