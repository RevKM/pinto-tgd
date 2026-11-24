@echo off
rem Makes the next Pinto release ready to push: see tools\release.py. Write its changes in
rem CHANGELOG.md first, under a new "## <version>" heading at the top.
cd /d "%~dp0"
python tools\release.py %*
echo.
pause
