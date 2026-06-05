@echo off
setlocal

echo.
echo ========================================
echo   Hermes Agent Upgrade (Safe Mode)
echo ========================================
echo.
echo This will:
echo   1. Create a timestamped backup of ALL configs
echo   2. Pull latest changes from GitHub
echo   3. Update Python dependencies
echo   4. Restore your configs
echo.
echo IMPORTANT: Make sure llama.cpp is NOT running
echo            and Hermes is stopped before upgrading.
echo.

set /p CONFIRM="Continue? [y/N] "
if /I not "%CONFIRM%"=="y" (
    echo Upgrade cancelled.
    exit /b 0
)

powershell -ExecutionPolicy Bypass -File "%~dp0upgrade_hermes.ps1"

endlocal
exit /b %errorlevel%
