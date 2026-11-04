@echo off
rem Puts PATH and variables back the way they were before the last Enviro Easy run.
call "%~dp0Setup-Development-Environment.bat" -Restore %*
exit /b %ERRORLEVEL%
