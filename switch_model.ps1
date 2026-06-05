$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath

function Stop-RunningLlamaServer {
    $process = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if ($process) {
        Write-Host "Stopping running llama-server.exe (PID: $($process.Id))..."
        Stop-Process -Id $process.Id -Force
        Start-Sleep -Seconds 2
        Write-Host "Stopped."
    } else {
        Write-Host "No running llama-server.exe found."
    }
}

function Test-PortInUse {
    param([int]$Port = 8080)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        return $false
    } catch {
        return $true
    } finally {
        if ($listener) { $listener.Stop() }
    }
}

$model = $args[0]

if (-not $model) {
    Write-Host @"
Usage: .\switch_model.ps1 <model>

Available models:
  qwen  - Start Qwen3.6-27B-MTP  (hermes_config.yaml)
  gemma - Start Gemma-4-31B-it    (hermes_config.gemma.yaml)
"@
    exit 1
}

$scriptPath = $null
$modelName = $null

switch ($model.Trim().ToLowerInvariant()) {
    'qwen' {
        $scriptPath = Join-Path $repoRoot 'start_qwen.ps1'
        $modelName = 'Qwen3.6-27B-MTP'
    }
    'gemma' {
        $scriptPath = Join-Path $repoRoot 'start_gemma.ps1'
        $modelName = 'Gemma-4-31B-it'
    }
    default {
        Write-Error "Unknown model '$model'. Use 'qwen' or 'gemma'."
        exit 1
    }
}

Write-Host "========================================"
Write-Host "  Switching to $modelName"
Write-Host "========================================"

# 1. Kill any running llama-server
Stop-RunningLlamaServer

# 2. Wait for port to be free
$maxWait = 30
$waited = 0
while ((Test-PortInUse -Port 8080) -and $waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
}

if (Test-PortInUse -Port 8080) {
    Write-Warning "Port 8080 is still in use after $maxWait seconds. Another service might be blocking it."
    Write-Host "Attempting to start anyway..."
}

# 3. Start the new model
Write-Host "Starting $modelName..."
Write-Host ""

& $scriptPath
