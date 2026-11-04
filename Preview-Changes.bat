@echo off
rem Shows what Enviro Easy WOULD change, without changing anything.
call "%~dp0Setup-Development-Environment.bat" -DryRun %*
exit /b %ERRORLEVEL%
