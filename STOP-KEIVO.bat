@echo off
if /i "%~1"=="--validate" exit /b 0
"%SystemRoot%\System32\wscript.exe" //nologo "%~dp0KEIVO-Launcher.vbs" stop
exit /b 0
