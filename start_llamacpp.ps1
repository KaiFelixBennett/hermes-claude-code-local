[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $configPath = Join-Path $repoRoot 'hermes_config.yaml'
} else {
    $configPath = $ConfigPath
}

$llamaToolsRoot = Join-Path $repoRoot 'tools\llama.cpp'

function Get-HermesModelConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path $configPath)) {
        return $null
    }

    $inModelBlock = $false
    foreach ($line in Get-Content $configPath) {
        if ($line -match '^model:\s*$') {
            $inModelBlock = $true
            continue
        }

        if ($inModelBlock -and $line -match '^[^\s]') {
            break
        }

        if ($inModelBlock -and $line -match ('^\s*' + [regex]::Escape($Key) + ':\s*(.+?)\s*$')) {
            $value = $matches[1]
            $value = $value -replace '\s+#.*$', ''
            $value = $value.Trim()

            if ($value.Length -ge 2) {
                $firstChar = $value[0]
                $lastChar = $value[$value.Length - 1]
                if (($firstChar -eq '"' -and $lastChar -eq '"') -or ($firstChar -eq "'" -and $lastChar -eq "'")) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }

            return $value.Trim()
        }
    }

    return $null
}

$chatTemplateFromConfig = Get-HermesModelConfigValue -Key 'chat_template'

function Get-FirstNonEmptyValue {
    param(
        [AllowNull()]
        [object[]]$Values = @()
    )

    foreach ($value in $Values) {
        if ($null -ne $value) {
            $text = [string]$value
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text.Trim()
            }
        }
    }

    return $null
}

function Get-LatestLlamaBinaryDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    return Get-ChildItem -Path $llamaToolsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $Pattern } |
        Sort-Object @(
            @{ Expression = {
                    if ($_.Name -match '^b(\d+)') {
                        [int]$matches[1]
                    } else {
                        -1
                    }
                }; Descending = $true },
            @{ Expression = { $_.Name }; Descending = $true }
        ) |
        Select-Object -First 1
}

function Resolve-LlamaServerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Backend,

        [string]$BinaryDir
    )

    if (-not (Test-Path $llamaToolsRoot)) {
        throw "llama.cpp directory not found: $llamaToolsRoot"
    }

    if (-not [string]::IsNullOrWhiteSpace($BinaryDir)) {
        $candidateServer = Join-Path (Join-Path $llamaToolsRoot $BinaryDir) 'llama-server.exe'
        if (Test-Path $candidateServer) {
            return $candidateServer
        }

        throw "llama-server.exe not found in configured binary_dir: $candidateServer"
    }

    $patterns = switch ($Backend.Trim().ToLowerInvariant()) {
        'auto' { @('b*-win-hip-radeon-x64', 'b*-win-vulkan-x64', 'b*-win-cuda-13.*-x64', 'b*-win-cuda-12.*-x64', 'b*-win-sycl-x64', 'b*-win-cpu-x64') }
        'hip' { @('b*-win-hip-radeon-x64') }
        'vulkan' { @('b*-win-vulkan-x64') }
        'cuda' { @('b*-win-cuda-13.*-x64', 'b*-win-cuda-12.*-x64') }
        'cuda13' { @('b*-win-cuda-13.*-x64') }
        'cuda12' { @('b*-win-cuda-12.*-x64') }
        'sycl' { @('b*-win-sycl-x64') }
        'cpu' { @('b*-win-cpu-x64') }
        default {
            throw "Unknown backend value '$Backend'. Allowed: auto, hip, vulkan, cuda, cuda12, cuda13, sycl, cpu."
        }
    }

    foreach ($pattern in $patterns) {
        $candidate = Get-LatestLlamaBinaryDirectory -Pattern $pattern
        if ($candidate) {
            return (Join-Path $candidate.FullName 'llama-server.exe')
        }
    }

    throw "No installed llama.cpp binary for backend '$Backend' found under $llamaToolsRoot. Install the matching release or set model.binary_dir."
}

function Get-LlamaDeviceInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerPath
    )

    $deviceOutput = cmd /c ('"' + $ServerPath + '" --list-devices 2>&1') | Out-String
    $deviceName = $null

    foreach ($line in $deviceOutput -split "`r?`n") {
        if ($line -match '^\s*([A-Za-z0-9._:-]+)\s*:') {
            $deviceName = $matches[1]
            break
        }
    }

    return [pscustomobject]@{
        Name = $deviceName
        Output = $deviceOutput
    }
}

$modelPath = Get-FirstNonEmptyValue -Values @(
    $env:HERMES_LLAMACPP_MODEL_PATH,
    (Get-HermesModelConfigValue -Key 'path')
)
$parallelSlots = Get-FirstNonEmptyValue -Values @(
    (Get-HermesModelConfigValue -Key 'parallel_slots'),
    '1'
)
$flashAttention = 'on'
$reasoningMode = 'off'
$reasoningBudget = '2048'
$reasoningBudgetMessage = 'Reasoning budget exhausted. Provide the best possible final answer now.'
$modelAlias = Get-HermesModelConfigValue -Key 'default'
$baseUrl = Get-HermesModelConfigValue -Key 'base_url'
$contextLength = Get-HermesModelConfigValue -Key 'context_length'
$batchSize = Get-FirstNonEmptyValue -Values @(
    (Get-HermesModelConfigValue -Key 'batch_size'),
    '512'
)
$ubatchSize = Get-FirstNonEmptyValue -Values @(
    (Get-HermesModelConfigValue -Key 'ubatch_size'),
    '512'
)
$cacheTypeK = Get-HermesModelConfigValue -Key 'cache_type_k'
$cacheTypeV = Get-HermesModelConfigValue -Key 'cache_type_v'
$temperature = Get-HermesModelConfigValue -Key 'temperature'
$topP = Get-HermesModelConfigValue -Key 'top_p'
$topK = Get-HermesModelConfigValue -Key 'top_k'
$minP = Get-HermesModelConfigValue -Key 'min_p'
$presencePenalty = Get-HermesModelConfigValue -Key 'presence_penalty'
$repeatPenalty = Get-HermesModelConfigValue -Key 'repeat_penalty'
$speculativeType = Get-HermesModelConfigValue -Key 'speculative_type'
$speculativeDraftTokens = Get-HermesModelConfigValue -Key 'speculative_draft_tokens'
$requestedBackend = Get-FirstNonEmptyValue -Values @(
    $env:HERMES_LLAMACPP_BACKEND,
    (Get-HermesModelConfigValue -Key 'backend')
)
$binaryDirOverride = Get-FirstNonEmptyValue -Values @(
    $env:HERMES_LLAMACPP_BINARY_DIR,
    (Get-HermesModelConfigValue -Key 'binary_dir')
)

if ([string]::IsNullOrWhiteSpace($modelAlias)) {
    $modelAlias = 'Qwen3.6-27B-MTP GGUF'
}

if ([string]::IsNullOrWhiteSpace($modelPath)) {
    throw "Model path is missing. Set model.path in hermes_config.yaml or HERMES_LLAMACPP_MODEL_PATH."
}

if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    $baseUrl = 'http://127.0.0.1:8080/v1'
}

if ([string]::IsNullOrWhiteSpace($contextLength)) {
    $contextLength = '131072'
}

if ([string]::IsNullOrWhiteSpace($requestedBackend)) {
    $requestedBackend = 'vulkan'
}

$serverPath = Resolve-LlamaServerPath -Backend $requestedBackend -BinaryDir $binaryDirOverride

try {
    $uri = [Uri]$baseUrl
} catch {
    throw "Invalid base_url in hermes_config.yaml: $baseUrl"
}

$hostIp = $uri.Host
$port = $uri.Port

if (-not (Test-Path $serverPath)) {
    throw "llama-server.exe not found: $serverPath"
}

if (-not (Test-Path $modelPath)) {
    throw "GGUF model not found: $modelPath"
}

if ($chatTemplatePath -and -not (Test-Path $chatTemplatePath)) {
    throw "Chat template not found: $chatTemplatePath"
}

$deviceInfo = Get-LlamaDeviceInfo -ServerPath $serverPath
$deviceName = $deviceInfo.Name

$arguments = @(
    '--host', $hostIp,
    '--port', "$port",
    '--model', $modelPath,
    '--alias', $modelAlias,
    '--ctx-size', "$contextLength",
    '--parallel', "$parallelSlots",
    '--flash-attn', $flashAttention,
    '--cache-reuse', '1024',
    '--kv-unified',              # Enables effective cache reuse.
    '--reasoning', $reasoningMode,
    '--jinja'
)

# Batch sizes for ROCm/HIP optimization
if (-not [string]::IsNullOrWhiteSpace($batchSize)) {
    $arguments += @('--batch-size', "$batchSize")
}

if (-not [string]::IsNullOrWhiteSpace($ubatchSize)) {
    $arguments += @('--ubatch-size', "$ubatchSize")
}

# KV-cache quantization for VRAM savings (essential for Gemma-4 on 24GB)
if (-not [string]::IsNullOrWhiteSpace($cacheTypeK)) {
    $arguments += @('--cache-type-k', "$cacheTypeK")
}

if (-not [string]::IsNullOrWhiteSpace($cacheTypeV)) {
    $arguments += @('--cache-type-v', "$cacheTypeV")
}

if ($chatTemplatePath) {
    $arguments += @('--chat-template-file', $chatTemplatePath)
}

if (-not [string]::IsNullOrWhiteSpace($temperature)) {
    $arguments += @('--temp', "$temperature")
}

if (-not [string]::IsNullOrWhiteSpace($topP)) {
    $arguments += @('--top-p', "$topP")
}

if (-not [string]::IsNullOrWhiteSpace($topK)) {
    $arguments += @('--top-k', "$topK")
}

if (-not [string]::IsNullOrWhiteSpace($minP)) {
    $arguments += @('--min-p', "$minP")
}

if (-not [string]::IsNullOrWhiteSpace($presencePenalty)) {
    $arguments += @('--presence-penalty', "$presencePenalty")
}

if (-not [string]::IsNullOrWhiteSpace($repeatPenalty)) {
    $arguments += @('--repeat-penalty', "$repeatPenalty")
}

if (
    -not [string]::IsNullOrWhiteSpace($speculativeType) -and
    $speculativeType.Trim().ToLowerInvariant() -ne 'none'
) {
    $arguments += @('--spec-type', "$speculativeType")
}

if (-not [string]::IsNullOrWhiteSpace($speculativeDraftTokens)) {
    $arguments += @('--spec-draft-n-max', "$speculativeDraftTokens")
}

if ($deviceName) {
    $arguments += @('--gpu-layers', 'all')
}

if ($reasoningMode -ne 'off') {
    $arguments += @(
        '--reasoning-budget', $reasoningBudget,
        '--reasoning-budget-message', $reasoningBudgetMessage
    )
}

if ($deviceName) {
    $arguments += @('--device', $deviceName)
}

Write-Host ''
Write-Host '========================================'
Write-Host '  llama.cpp Server'
Write-Host '========================================'
Write-Host ("Backend: {0}" -f $requestedBackend)
Write-Host ("Binary : {0}" -f $serverPath)
Write-Host ("Model  : {0}" -f $modelPath)
Write-Host ("Alias  : {0}" -f $modelAlias)
Write-Host ("API    : {0}" -f $baseUrl)
Write-Host ("Ctx    : {0}" -f $contextLength)
Write-Host ("Tpl    : {0}" -f $chatTemplatePath)
Write-Host ("Slots  : {0}" -f $parallelSlots)
Write-Host ("Flash  : {0}" -f $flashAttention)
if (-not [string]::IsNullOrWhiteSpace($batchSize)) {
    Write-Host ("Batch  : {0}" -f $batchSize)
}
if (-not [string]::IsNullOrWhiteSpace($ubatchSize)) {
    Write-Host ("UBatch : {0}" -f $ubatchSize)
}
if (-not [string]::IsNullOrWhiteSpace($cacheTypeK)) {
    Write-Host ("CacheK : {0}" -f $cacheTypeK)
}
if (-not [string]::IsNullOrWhiteSpace($cacheTypeV)) {
    Write-Host ("CacheV : {0}" -f $cacheTypeV)
}
if (
    -not [string]::IsNullOrWhiteSpace($temperature) -or
    -not [string]::IsNullOrWhiteSpace($topP) -or
    -not [string]::IsNullOrWhiteSpace($topK) -or
    -not [string]::IsNullOrWhiteSpace($minP) -or
    -not [string]::IsNullOrWhiteSpace($presencePenalty) -or
    -not [string]::IsNullOrWhiteSpace($repeatPenalty)
) {
    Write-Host (
        "Sample : temp={0}, top_p={1}, top_k={2}, min_p={3}, presence={4}, repeat={5}" -f
        $temperature,
        $topP,
        $topK,
        $minP,
        $presencePenalty,
        $repeatPenalty
    )
}
if (
    -not [string]::IsNullOrWhiteSpace($speculativeType) -and
    $speculativeType.Trim().ToLowerInvariant() -ne 'none'
) {
    if (-not [string]::IsNullOrWhiteSpace($speculativeDraftTokens)) {
        Write-Host ("Spec   : {0} (draft tokens {1})" -f $speculativeType, $speculativeDraftTokens)
    } else {
        Write-Host ("Spec   : {0}" -f $speculativeType)
    }
}
if ($reasoningMode -eq 'off') {
    Write-Host ("Think  : {0}" -f $reasoningMode)
} else {
    Write-Host ("Think  : {0} (budget {1})" -f $reasoningMode, $reasoningBudget)
}
if ($deviceName) {
    Write-Host ("Device : {0}" -f $deviceName)
} else {
    Write-Host 'Device : auto'
}
Write-Host ''
Write-Host 'Note: This launcher uses only the exact configured MTP GGUF.'
Write-Host ''

Push-Location (Split-Path -Parent $serverPath)
try {
    & $serverPath @arguments
} finally {
    Pop-Location
}