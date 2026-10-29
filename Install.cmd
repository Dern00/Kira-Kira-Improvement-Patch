@echo off
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "patch_exit=%ERRORLEVEL%"
if not "%patch_exit%"=="0" pause
exit /b %patch_exit%
