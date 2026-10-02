@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "%~dp0az.ps1" %*
exit /b %errorlevel%
