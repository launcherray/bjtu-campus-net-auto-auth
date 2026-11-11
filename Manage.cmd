@echo off
REM SPDX-License-Identifier: MIT
REM Copyright (c) 2026 launcherray
REM Project: https://github.com/launcherray/bjtu-campus-net-auto-auth
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0BJTUWebLogin.ps1" -Action Menu
if errorlevel 1 pause
