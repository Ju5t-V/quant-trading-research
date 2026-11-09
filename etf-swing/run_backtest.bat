@echo off
cd /d "%~dp0"
".venv\Scripts\python.exe" backtest.py %*
echo.
pause
