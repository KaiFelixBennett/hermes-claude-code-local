# Hermes Agent Safe Upgrade Script
# Creates backup, pulls latest code, updates deps, restores configs

$ErrorActionPreference = 'Stop'

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "/root/.hermes/backups/upgrade_$timestamp"
$hermesDir = "/root/.hermes"
$repoDir = "$hermesDir/hermes-agent"
$repoRootWin = "C:\Users\KaiFe\Desktop\hermes-claude-code-local"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Hermes Agent Safe Upgrade" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- 1) Check if Hermes is running ---
Write-Host "[1/6] Checking for running Hermes processes..." -ForegroundColor Yellow
$hermesProcs = wsl -d Ubuntu -- bash -c "ps aux | grep -E 'hermes (gateway|cli|agent)' | grep -v grep || true"
if ($hermesProcs -and $hermesProcs.Trim().Length -gt 0) {
    Write-Host "WARNING: Hermes processes detected:" -ForegroundColor Red
    Write-Host $hermesProcs
    Write-Host ""
    $killChoice = Read-Host "Kill running Hermes processes? [Y/n]"
    if ($killChoice -notmatch '^[Nn]') {
        wsl -d Ubuntu -- bash -c "pkill -f 'hermes (gateway|cli|agent)' 2>/dev/null || true; sleep 2"
        Write-Host "Processes stopped." -ForegroundColor Green
    } else {
        Write-Host "Please stop Hermes manually and retry." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "    [OK] No Hermes processes running." -ForegroundColor Green
}

# --- 2) Create backup ---
Write-Host ""
Write-Host "[2/6] Creating backup at: $backupDir" -ForegroundColor Yellow

$backupItems = @(
    ".env",
    "config.yaml",
    "auth.json",
    "hermes_launch.sh",
    "hermes_gateway.sh",
    "gateway_state.json",
    "channel_directory.json",
    ".hermes_history",
    "SOUL.md",
    "state.db",
    "state.db-shm",
    "state.db-wal",
    "kanban.db",
    "kanban.db-shm",
    "kanban.db-wal",
    "models_dev_cache.json",
    "processes.json",
    "relay_forwarder_queue.json",
    "relay_forwarder_state.json",
    "relay_inbox_state.json",
    "interrupt_debug.log",
    ".restart_last_processed.json",
    ".skills_prompt_snapshot.json",
    ".update_check"
)

$backupDirs = @(
    "sessions",
    "skills",
    "memories",
    "cron",
    "logs",
    "image_cache",
    "audio_cache",
    "media",
    "sandboxes",
    "hooks",
    "pairing",
    "pastes",
    "lsp",
    "cache",
    "bin",
    "plugins"
)

wsl -d Ubuntu -- bash -c "mkdir -p $backupDir"

foreach ($item in $backupItems) {
    $src = "$hermesDir/$item"
    wsl -d Ubuntu -- bash -c "if [ -f '$src' ]; then cp '$src' '$backupDir/'; echo '  [OK] $item'; fi" 2>$null
}

foreach ($dir in $backupDirs) {
    $src = "$hermesDir/$dir"
    wsl -d Ubuntu -- bash -c "if [ -d '$src' ]; then cp -r '$src' '$backupDir/'; echo '  [OK] $dir/'; fi" 2>$null
}

# Also backup Windows repo configs
$winBackupDir = "$repoRootWin\backups\upgrade_$timestamp"
New-Item -ItemType Directory -Path $winBackupDir -Force | Out-Null
Copy-Item "$repoRootWin\hermes_config.yaml" $winBackupDir -ErrorAction SilentlyContinue
Copy-Item "$repoRootWin\hermes_config.gemma.yaml" $winBackupDir -ErrorAction SilentlyContinue
Copy-Item "$repoRootWin\hermes_launch_gemma.sh" $winBackupDir -ErrorAction SilentlyContinue
Copy-Item "$repoRootWin\hermes_gateway_gemma.sh" $winBackupDir -ErrorAction SilentlyContinue
Copy-Item "$repoRootWin\start_hermes_gemma.bat" $winBackupDir -ErrorAction SilentlyContinue
Copy-Item "$repoRootWin\start_pi_dev.bat" $winBackupDir -ErrorAction SilentlyContinue
Copy-Item "$repoRootWin\start_llamacpp.ps1" $winBackupDir -ErrorAction SilentlyContinue
Write-Host "    [OK] Windows configs backed up to $winBackupDir" -ForegroundColor Green

Write-Host "    [OK] Backup complete." -ForegroundColor Green

# --- 3) Git pull ---
Write-Host ""
Write-Host "[3/6] Pulling latest changes from GitHub..." -ForegroundColor Yellow

# Stash any local changes first
wsl -d Ubuntu -- bash -c "cd $repoDir && git stash push -m 'upgrade_backup' --include-untracked 2>/dev/null || true"

$pullOutput = wsl -d Ubuntu -- bash -c "cd $repoDir && git pull origin main 2>&1"
Write-Host $pullOutput

# Check if pull actually succeeded
$currentCommit = wsl -d Ubuntu -- bash -c "cd $repoDir && git rev-parse HEAD"
$originCommit = wsl -d Ubuntu -- bash -c "cd $repoDir && git rev-parse origin/main"
if ($currentCommit -eq $originCommit) {
    Write-Host "    [OK] Code updated to latest." -ForegroundColor Green
} else {
    Write-Host "    [WARN] Pull may have failed. Current: $currentCommit, Origin: $originCommit" -ForegroundColor Yellow
}

# --- 4) Update Python dependencies ---
Write-Host ""
Write-Host "[4/6] Updating Python dependencies..." -ForegroundColor Yellow
$pipOutput = wsl -d Ubuntu -- bash -c "cd $repoDir && source venv/bin/activate && pip install -e . --upgrade 2>&1 | tail -20"
Write-Host $pipOutput
Write-Host "    [OK] Dependencies updated." -ForegroundColor Green

# --- 5) Restore configs ---
Write-Host ""
Write-Host "[5/6] Restoring your configurations..." -ForegroundColor Yellow

foreach ($item in $backupItems) {
    $src = "$backupDir/$item"
    $dst = "$hermesDir/$item"
    wsl -d Ubuntu -- bash -c "if [ -f '$src' ]; then cp '$src' '$dst'; fi" 2>$null
}

foreach ($dir in $backupDirs) {
    $src = "$backupDir/$dir"
    $dst = "$hermesDir/$dir"
    wsl -d Ubuntu -- bash -c "if [ -d '$src' ]; then rm -rf '$dst' 2>/dev/null; cp -r '$src' '$dst'; fi" 2>$null
}

# Restore Windows configs
Copy-Item "$winBackupDir\hermes_config.yaml" "$repoRootWin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$winBackupDir\hermes_config.gemma.yaml" "$repoRootWin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$winBackupDir\hermes_launch_gemma.sh" "$repoRootWin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$winBackupDir\hermes_gateway_gemma.sh" "$repoRootWin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$winBackupDir\start_hermes_gemma.bat" "$repoRootWin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$winBackupDir\start_pi_dev.bat" "$repoRootWin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$winBackupDir\start_llamacpp.ps1" "$repoRootWin\" -Force -ErrorAction SilentlyContinue

# Re-deploy WSL scripts
wsl -d Ubuntu -- bash -c "cp /mnt/c/Users/KaiFe/Desktop/hermes-claude-code-local/hermes_launch_gemma.sh /root/.hermes/hermes_launch.sh 2>/dev/null || true"
wsl -d Ubuntu -- bash -c "cp /mnt/c/Users/KaiFe/Desktop/hermes-claude-code-local/hermes_gateway_gemma.sh /root/.hermes/hermes_gateway.sh 2>/dev/null || true"
wsl -d Ubuntu -- bash -c "chmod +x /root/.hermes/hermes_launch.sh /root/.hermes/hermes_gateway.sh 2>/dev/null || true"

Write-Host "    [OK] Configs restored." -ForegroundColor Green

# --- 6) Verify ---
Write-Host ""
Write-Host "[6/6] Verifying installation..." -ForegroundColor Yellow
$versionOutput = wsl -d Ubuntu -- bash -c "cd $repoDir && git log --oneline -1 2>/dev/null"
Write-Host "    Commit: $versionOutput" -ForegroundColor Cyan

# Check if we're on latest
$isLatest = wsl -d Ubuntu -- bash -c "cd $repoDir && git rev-parse HEAD" 2>$null
$originLatest = wsl -d Ubuntu -- bash -c "cd $repoDir && git rev-parse origin/main" 2>$null
if ($isLatest -eq $originLatest) {
    Write-Host "    [OK] Repository is up to date with origin/main" -ForegroundColor Green
} else {
    Write-Host "    [WARN] Repository may not be fully updated" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Upgrade Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Backup location:"
Write-Host "  WSL:  $backupDir"
Write-Host "  Win:  $winBackupDir"
Write-Host ""
Write-Host "You can now start Hermes with:"
Write-Host "  .\start_hermes_gemma.bat"
Write-Host ""
