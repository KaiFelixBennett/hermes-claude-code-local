@echo off
setlocal

echo.
echo ========================================
echo   pi.dev Starter (Gemma-4-31B-it)
echo   Provider: llama-cpp-local
echo ========================================
echo.

REM Check if llama.cpp is running
echo [1/2] Checking llama.cpp on http://127.0.0.1:8080 ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 3; Write-Host ('    [OK] llama.cpp running with: ' + ($r.data.id -join ', ')) } catch { Write-Host '    [WARN] llama.cpp not responding'; exit 1 }"
if errorlevel 1 (
    echo.
    echo [ERROR] llama.cpp is not running. Please start it first with:
    echo         .\start_gemma.bat
    echo.
    pause
    exit /b 1
)

REM Start pi.dev with local llama.cpp provider
echo [2/2] Starting pi.dev with Gemma-4-31B-it ...
echo.
echo Provider: llama-cpp-local
echo Model:    Gemma-4-31B-it GGUF
echo API:      http://127.0.0.1:8080/v1
echo.
echo Press Ctrl+C to exit, then type 'exit' to close.
echo.

pi --provider llama-cpp-local --model "Gemma-4-31B-it GGUF"

endlocal
exit /b %errorlevel%
