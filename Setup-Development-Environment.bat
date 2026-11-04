@echo off
setlocal
title Enviro Easy - Development Environment Setup

if not exist "%~dp0EnviroEasy.ps1" (
    echo.
    echo   ERROR: EnviroEasy.ps1 was not found next to this file.
    echo   Download the whole project ^(not just the .bat file^) and try again.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0EnviroEasy.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
pause
exit /b %EXITCODE%
