@echo off
REM Wrapper for load-env.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\load-env.ps1" %*
