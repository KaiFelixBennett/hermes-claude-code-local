@echo off
setlocal

set "REPO_ROOT_WIN=%~dp0"
set "CONFIG_PATH=%~dp0hermes_config.gemma.yaml"
set "HERMES_BASE_URL=http://127.0.0.1:8080/v1"
set "HERMES_REPO_WSL="
set "HERMES_HELPER_SCRIPT=%~dp0hermes_batch_helper.ps1"
set "LLAMA_SERVER_SCRIPT=%~dp0start_llamacpp.ps1"
set "COMBINED_STARTER=%~dp0start_hermes_claude_local.bat"

if /I "%HERMES_USE_CLAUDE_LITELLM%"=="1" goto :run_combined
if /I "%HERMES_USE_CLAUDE_LITELLM%"=="true" goto :run_combined

set "REPO_WIN_NOTRAIL=%REPO_ROOT_WIN:~0,-1%"
for /f "delims=" %%P in ('wsl wslpath -u "%REPO_WIN_NOTRAIL%"') do set "HERMES_REPO_WSL=%%P"
if "%HERMES_REPO_WSL%"=="" (
    echo [ERROR] Could not resolve WSL path for this repository.
    echo         Make sure WSL2 is installed with at least one Linux distribution.
    pause
    exit /b 1
)

call :read_base_url

echo.
echo ========================================
echo   Hermes Agent Starter
echo   Provider: llama.cpp (Gemma-4-31B-it GGUF)
echo ========================================
echo.

REM --- 1) Check llama.cpp OpenAI endpoint on Windows localhost ---
echo [1/3] Checking llama.cpp on %HERMES_BASE_URL% ...
call :check_llama
if errorlevel 1 (
    if not exist "%LLAMA_SERVER_SCRIPT%" (
        echo     [ERROR] %LLAMA_SERVER_SCRIPT% was not found.
        pause
        exit /b 1
    )

    echo     [INFO] Starting llama.cpp with Gemma-4 in a background window ...
    start "llama.cpp Server (Gemma-4)" powershell -NoExit -ExecutionPolicy Bypass -File "%LLAMA_SERVER_SCRIPT%" -ConfigPath "%CONFIG_PATH%"

    call :wait_for_llama
    if errorlevel 1 (
        echo     [ERROR] llama.cpp is still not responding at %HERMES_BASE_URL%
        echo     Check the new window for the detailed error message.
        echo.
        pause
        exit /b 1
    )
)
echo     [OK] llama.cpp is running with Gemma-4.

REM --- 2) Start gateway in background (Telegram) ---
echo [2/3] Starting Hermes Gateway (Telegram) ...
start "Hermes Gateway" cmd /k "wsl -d Ubuntu -- /bin/bash /root/.hermes/hermes_gateway.sh"

REM Short wait to give the gateway time to initialize
timeout /t 5 /nobreak >nul

REM --- 3) Start interactive CLI ---
echo [3/3] Starting Hermes CLI (interactive) ...
echo.
wsl -d Ubuntu -- /bin/bash /root/.hermes/hermes_launch.sh

endlocal
exit /b 0

:run_combined
if not exist "%COMBINED_STARTER%" (
    echo [ERROR] %COMBINED_STARTER% was not found.
    pause
    exit /b 1
)

call "%COMBINED_STARTER%"
endlocal
exit /b %errorlevel%

:read_base_url
if not exist "%HERMES_HELPER_SCRIPT%" exit /b 0
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HERMES_HELPER_SCRIPT%" -Action GetModelBaseUrl -ConfigPath "%CONFIG_PATH%"`) do set "HERMES_BASE_URL=%%I"
exit /b 0

:check_llama
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERMES_HELPER_SCRIPT%" -Action TestEndpoint -BaseUrl "%HERMES_BASE_URL%"
exit /b %errorlevel%

:wait_for_llama
for /L %%N in (1,1,15) do (
    call :check_llama
    if not errorlevel 1 exit /b 0
    timeout /t 2 /nobreak >nul
)
exit /b 1
