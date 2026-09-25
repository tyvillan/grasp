@echo off
rem Runs grasp.ps1 without changing PowerShell's script policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0grasp.ps1" %*
exit /b %ERRORLEVEL%
