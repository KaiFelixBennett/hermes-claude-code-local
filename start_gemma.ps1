$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSCommandPath
$configPath = Join-Path $repoRoot 'hermes_config.gemma.yaml'

& (Join-Path $repoRoot 'start_llamacpp.ps1') -ConfigPath $configPath
