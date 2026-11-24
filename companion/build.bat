@echo off
rem Builds dist\PuppyCompanion\PuppyCompanion.exe on Windows.
rem Needs Python 3.10 or newer from python.org (with tcl/tk, the default) on PATH.
setlocal
cd /d "%~dp0"
if not exist .venv-build (python -m venv .venv-build || goto :fail)
call .venv-build\Scripts\activate.bat || goto :fail
python -m pip install --upgrade pip >nul
python -m pip install -r requirements-build.txt || goto :fail
python -m unittest discover -s tests || goto :fail
pyinstaller --noconfirm --clean --windowed --name PuppyCompanion --icon assets\PuppyCompanion.ico --paths . run_companion.py || goto :fail
rem the program is a windowed one: start /wait gives its exit code to errorlevel
start "" /wait dist\PuppyCompanion\PuppyCompanion.exe --selftest selftest.txt
set RC=%errorlevel%
type selftest.txt
if not "%RC%"=="0" goto :fail
echo.
echo Built: %cd%\dist\PuppyCompanion\PuppyCompanion.exe
exit /b 0
:fail
echo.
echo Build failed.
exit /b 1
