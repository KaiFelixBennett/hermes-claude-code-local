#!/usr/bin/env bash
# Hermes Local Stack — One-Command Setup for Linux / macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/KaiFelixBennett/hermes-claude-code-local/main/setup.sh | bash
set -euo pipefail

###############################################################################
# Colors
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[SETUP]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

###############################################################################
# Detect platform
###############################################################################
IS_LINUX=0
IS_MACOS=0
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Linux)   IS_LINUX=1 ;;
    Darwin)  IS_MACOS=1 ;;
    *)       error "Unsupported platform: $PLATFORM"; exit 1 ;;
esac

info "Detected platform: ${PLATFORM}"

###############################################################################
# Check prerequisites
###############################################################################
check_prerequisites() {
    info "Checking system requirements..."

    # RAM check
    if [ "$IS_LINUX" = "1" ]; then
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    else
        TOTAL_RAM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1024/1024/1024}')
    fi

    if [ "$TOTAL_RAM_GB" -lt 16 ]; then
        warn "You have ${TOTAL_RAM_GB} GB RAM. 16 GB minimum recommended (32 GB for best experience)."
        read -p "Continue anyway? [y/N] " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Aborted by user."; exit 1
        fi
    else
        success "RAM: ${TOTAL_RAM_GB} GB"
    fi

    # Disk space check
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
    AVAIL_DISK=$(df -BG "$REPO_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$AVAIL_DISK" -lt 10 ]; then
        warn "Available disk space: ${AVAIL_DISK} GB. At least 10 GB recommended."
    else
        success "Disk space: ${AVAIL_DISK} GB available"
    fi

    # Python check
    if command -v python3 &>/dev/null; then
        PYTHON_CMD="python3"
        success "Python3 found: $($PYTHON_CMD --version 2>&1)"
    elif command -v python &>/dev/null; then
        PYTHON_CMD="python"
        success "Python found: $($PYTHON_CMD --version 2>&1)"
    else
        error "Python not found. Please install Python 3.10+ first."
        exit 1
    fi

    # pip check
    if ! $PYTHON_CMD -m pip --version &>/dev/null; then
        error "pip not found. Please install pip first."
        exit 1
    fi
}

###############################################################################
# Install Hermes Agent
###############################################################################
install_hermes() {
    info "Checking Hermes Agent installation..."

    if command -v hermes &>/dev/null; then
        success "Hermes is already installed: $(hermes --version 2>&1 || echo 'version unknown')"
        return 0
    fi

    info "Installing Hermes Agent via pip..."
    PIP_OPTS=""
    if [ "$IS_LINUX" = "1" ]; then
        PIP_OPTS="--break-system-packages --ignore-installed"
    fi
    $PYTHON_CMD -m pip install $PIP_OPTS --upgrade hermes-agent
    if [ $? -eq 0 ]; then
        success "Hermes Agent installed successfully"
    else
        error "Failed to install Hermes Agent"
        exit 1
    fi
}

###############################################################################
# Configure model path
###############################################################################
configure_model() {
    CONFIG_FILE="${REPO_DIR}/hermes_config.yaml"

    if [ ! -f "$CONFIG_FILE" ]; then
        error "hermes_config.yaml not found in ${REPO_DIR}"
        exit 1
    fi

    info "Checking model configuration..."

    # Extract current model path from config
    CURRENT_PATH=$(grep -A1 '^\s*path:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed "s/.*path:\s*['\"]*//;s/['\"].*//" | tr -d ' ')

    if [ -z "$CURRENT_PATH" ]; then
        warn "No model path configured in hermes_config.yaml"
    elif [ ! -f "$CURRENT_PATH" ]; then
        warn "Configured model not found at: $CURRENT_PATH"
    else
        success "Model found at: $CURRENT_PATH"
        return 0
    fi

    # Ask user for model path
    echo ""
    info "Please provide the path to your GGUF model file:"
    echo "   (Press Enter to download a default model instead)"
    read -p "Model path: " -r MODEL_PATH

    if [ -z "$MODEL_PATH" ]; then
        # Download default model
        info "Downloading default model (Qwen3.6-27B Q4_K_M)..."
        local MODELS_DIR="${HOME}/.hermes/models"
        mkdir -p "$MODELS_DIR"
        MODEL_PATH="${MODELS_DIR}/qwen3.6-27b-mtp-Q4_K_M.gguf"

        if [ ! -f "$MODEL_PATH" ]; then
            info "Downloading from Hugging Face..."
            if command -v huggingface-cli &>/dev/null; then
                huggingface-cli download unsloth/Qwen3.6-27B-MTP-GGUF \
                    Qwen3.6-27B-Q4_K_M-mtp.gguf \
                    --local-dir "$MODELS_DIR"
            elif command -v wget &>/dev/null; then
                wget -O "$MODEL_PATH" "https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF/resolve/main/Qwen3.6-27B-Q4_K_M-mtp.gguf"
            elif command -v curl &>/dev/null; then
                curl -L -o "$MODEL_PATH" "https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF/resolve/main/Qwen3.6-27B-Q4_K_M-mtp.gguf"
            else
                error "No download tool found (huggingface-cli, wget, or curl)"
                exit 1
            fi
        fi
        success "Model downloaded to: $MODEL_PATH"
    elif [ ! -f "$MODEL_PATH" ]; then
        error "Model file not found at: $MODEL_PATH"
        exit 1
    fi

    # Update config with new path
    if grep -q '^\s*path:' "$CONFIG_FILE"; then
        sed -i "s|^\s*path:.*|  path: '${MODEL_PATH}'|" "$CONFIG_FILE"
    else
        sed -i '/^model:/a\  path: '"'"'${MODEL_PATH}'"'"'' "$CONFIG_FILE"
    fi
    success "Model path updated in hermes_config.yaml"
}

###############################################################################
# Detect GPU backend
###############################################################################
detect_backend() {
    CONFIG_FILE="${REPO_DIR}/hermes_config.yaml"
    CURRENT_BACKEND=$(grep -A1 '^\s*backend:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed "s/.*backend:\s*['\"]*//;s/['\"].*//" | tr -d ' ')

    if [ -n "$CURRENT_BACKEND" ]; then
        info "Current backend: $CURRENT_BACKEND"
        return 0
    fi

    info "Detecting GPU backend..."

    # Check for NVIDIA GPU
    if command -v nvidia-smi &>/dev/null; then
        BACKEND="cuda"
        success "NVIDIA GPU detected, using CUDA backend"
    # Check for AMD GPU (Linux)
    elif [ -d "/dev/kfd" ] || lsmod | grep -q amdgpu 2>/dev/null; then
        BACKEND="hip"
        success "AMD GPU detected, using HIP backend"
    else
        BACKEND="cpu"
        warn "No GPU detected, defaulting to CPU (slower but works)"
    fi

    # Update config
    if grep -q '^\s*backend:' "$CONFIG_FILE"; then
        sed -i "s|^\s*backend:.*|  backend: '${BACKEND}'|" "$CONFIG_FILE"
    else
        sed -i '/^model:/a\  backend: '"'"'${BACKEND}'"'"'' "$CONFIG_FILE"
    fi
}

###############################################################################
# Install llama.cpp (Linux native)
###############################################################################
install_llamacpp() {
    info "Checking llama.cpp..."

    # Check if system-wide llama.cpp is available
    if command -v llama-server &>/dev/null; then
        success "llama-server found: $(command -v llama-server)"
        return 0
    fi

    # Try to install via package manager first
    if [ "$IS_LINUX" = "1" ]; then
        if command -v apt-get &>/dev/null; then
            info "Installing llama.cpp via apt..."
            sudo apt-get update && sudo apt-get install -y llama-cpp-server 2>/dev/null && {
                success "llama.cpp installed via package manager"
                return 0
            } || true
        fi
    fi

    # Fall back to pip installation
    info "Installing llama.cpp via pip..."
    $PYTHON_CMD -m pip install llama-cpp-python --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu
    success "llama.cpp installed"
}

###############################################################################
# Start services
###############################################################################
start_services() {
    info "Starting llama.cpp server..."

    # Read model path from config
    CONFIG_FILE="${REPO_DIR}/hermes_config.yaml"
    MODEL_PATH=$(grep -A1 '^\s*path:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed "s/.*path:\s*['\"]*//;s/['\"].*//" | tr -d ' ')

    if [ -z "$MODEL_PATH" ] || [ ! -f "$MODEL_PATH" ]; then
        error "No valid model path found. Please configure model.path in hermes_config.yaml"
        exit 1
    fi

    # Start llama-server in background
    llama-server \
        --model "$MODEL_PATH" \
        --host 127.0.0.1 \
        --port 8080 \
        --ctx-size 65536 \
        --threads $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) \
        > /tmp/llama-server.log 2>&1 &

    LLAMA_PID=$!
    echo "$LLAMA_PID" > /tmp/hermes-llama.pid

    # Wait for llama.cpp to be ready
    info "Waiting for llama.cpp to start..."
    for i in $(seq 1 30); do
        if curl -s http://127.0.0.1:8080/v1/models > /dev/null 2>&1; then
            success "llama.cpp is running (PID: $LLAMA_PID)"
            break
        fi
        if [ $i -eq 30 ]; then
            error "llama.cpp failed to start. Check /tmp/llama-server.log"
            exit 1
        fi
        sleep 2
    done

    # Start Hermes
    info "Starting Hermes Agent..."
    if command -v hermes &>/dev/null; then
        hermes
    else
        error "Hermes not found. Run setup again."
        exit 1
    fi
}

###############################################################################
# Main
###############################################################################
main() {
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  Hermes Local Stack — Setup             ║"
    echo "║  Run Hermes + Claude Code locally       ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    install_hermes
    configure_model
    detect_backend
    install_llamacpp

    echo ""
    success "Setup complete!"
    echo ""
    info "To start Hermes, run:"
    echo "  make start          # Start Hermes + llama.cpp"
    echo "  make claude-bridge  # Start with Claude Code bridge"
    echo ""
}

main "$@"
