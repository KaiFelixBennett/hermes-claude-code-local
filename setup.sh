#!/usr/bin/env bash
# Hermes Local Stack — One-Command Setup for Linux / macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/KaiFelixBennett/hermes-claude-code-local/main/setup.sh | bash
#
# Written for the bash 3.2 that ships with macOS: no ${var,,}, no mapfile,
# no expansion of empty arrays under set -u.
#
# Optional environment variables:
#   HERMES_LOCAL_DIR               where `curl | bash` clones the repo (default: ~/hermes-claude-code-local)
#   HERMES_LOCAL_REF               branch to clone (default: main)
#   HERMES_SETUP_NONINTERACTIVE=1  never prompt (CI, containers)
#   HERMES_SETUP_MODEL             path to a GGUF file, "download" for the default model, or "skip"
#   HERMES_LLAMACPP_SOURCE         brew | release (macOS default: brew if installed, else release)
#   HERMES_LLAMACPP_BUILD          llama.cpp release tag to download (default below)
set -euo pipefail

###############################################################################
# Colors
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# printf, not echo -e: echo -e would read the "\c" in a Windows path such
# as E:\Coding\... as "stop output here".
info()    { printf '%b%s\n' "${CYAN}[SETUP]${NC} " "$*"; }
success() { printf '%b%s\n' "${GREEN}[OK]${NC}    " "$*"; }
warn()    { printf '%b%s\n' "${YELLOW}[WARN]${NC}  " "$*"; }
error()   { printf '%b%s\n' "${RED}[ERROR]${NC} " "$*" >&2; }

###############################################################################
# Settings
###############################################################################
REPO_URL="${HERMES_LOCAL_REPO:-https://github.com/KaiFelixBennett/hermes-claude-code-local.git}"
HERMES_INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"
# Pinned llama.cpp build: tested in CI on macOS and Ubuntu. The "latest"
# release on GitHub carries no binaries, so the tag is named explicitly.
LLAMACPP_BUILD="${HERMES_LLAMACPP_BUILD:-b11407}"
DEFAULT_MODEL_REPO="unsloth/Qwen3.6-27B-MTP-GGUF"
DEFAULT_MODEL_FILE="Qwen3.6-27B-Q4_K_M.gguf"
# Saved with "MTP" in the name: start_llamacpp.sh turns on MTP speculative
# decoding only for files named that way, because llama-server refuses to
# start when MTP is requested for a model without MTP layers.
DEFAULT_MODEL_LOCAL="Qwen3.6-27B-MTP-Q4_K_M.gguf"

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

ARCH="$(uname -m)"
# A shell running under Rosetta reports x86_64 on Apple Silicon.
if [ "$IS_MACOS" = "1" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
    ARCH="arm64"
fi

NONINTERACTIVE=0
case "${HERMES_SETUP_NONINTERACTIVE:-0}" in
    1|true|TRUE|yes|YES) NONINTERACTIVE=1 ;;
esac
# Without a terminal (CI, Docker) nobody can answer a prompt.
if [ "$NONINTERACTIVE" = "0" ] && ! (: </dev/tty) 2>/dev/null; then
    NONINTERACTIVE=1
fi

# ask VAR "prompt": reads from the terminal, also under `curl | bash`.
# Leaves VAR empty in non-interactive mode.
ask() {
    local answer=""
    if [ "$NONINTERACTIVE" = "0" ]; then
        read -r -p "$2" answer < /dev/tty || answer=""
    fi
    printf -v "$1" '%s' "$answer"
}

###############################################################################
# Locate the repository, clone it when run through `curl | bash`
###############################################################################
locate_repo() {
    local here=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [ -n "$here" ] && [ -f "$here/hermes_config.yaml" ]; then
        REPO_DIR="$here"
        return 0
    fi
    if [ -f "$PWD/hermes_config.yaml" ] && [ -f "$PWD/setup.sh" ]; then
        REPO_DIR="$PWD"
        return 0
    fi
    return 1
}

bootstrap_clone() {
    local dir="${HERMES_LOCAL_DIR:-$HOME/hermes-claude-code-local}"
    local ref="${HERMES_LOCAL_REF:-main}"

    if [ -d "$dir/.git" ]; then
        info "Using the existing clone in $dir"
        git -C "$dir" pull --ff-only --quiet 2>/dev/null \
            || warn "Could not update $dir (local changes?), continuing with it as it is"
    else
        if ! git --version >/dev/null 2>&1; then
            error "git is required. On macOS run: xcode-select --install"
            exit 1
        fi
        info "Cloning the repository into $dir"
        git clone --depth 1 --branch "$ref" "$REPO_URL" "$dir"
    fi
    exec bash "$dir/setup.sh" "$@"
}

###############################################################################
# Read and write values in the model: block of hermes_config.yaml
###############################################################################
get_model_value() {
    awk -v wanted="$1" '
        /^model:[[:space:]]*$/ { in_model=1; next }
        in_model && /^[^[:space:]#]/ { in_model=0 }
        in_model && $1 == wanted ":" {
            value = $0
            sub(/^[^:]+:[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/^['\''"]/, "", value)
            gsub(/['\''"]$/, "", value)
            gsub(/'\'''\''/, "'\''", value)
            print value
            exit
        }
    ' "$CONFIG_FILE"
}

# Replaces the key inside model:, or adds it at the end of that block.
# Uses awk instead of `sed -i`, whose syntax differs between macOS and Linux.
set_model_value() {
    local key="$1" value tmp
    value="$(printf '%s' "$2" | sed "s/'/''/g")"
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        function line() { return "  " key ": '\''" value "'\''" }
        /^model:[[:space:]]*$/ { in_model=1; print; next }
        in_model && /^[^[:space:]#]/ {
            if (!done) { print line(); done=1 }
            in_model=0
        }
        in_model && !done && $1 == key ":" { print line(); done=1; next }
        { print }
        END { if (in_model && !done) print line() }
    ' "$CONFIG_FILE" > "$tmp"
    cat "$tmp" > "$CONFIG_FILE"
    rm -f "$tmp"
}

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
        if [ "$NONINTERACTIVE" = "0" ]; then
            ask REPLY "Continue anyway? [y/N] "
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error "Aborted by user."; exit 1
            fi
        fi
    else
        success "RAM: ${TOTAL_RAM_GB} GB"
    fi

    # Disk space check
    if [ "$IS_LINUX" = "1" ]; then
        AVAIL_DISK=$(df -BG "$REPO_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
    else
        # macOS df doesn't support -BG, use -g instead
        AVAIL_DISK=$(df -g "$REPO_DIR" | awk 'NR==2 {print $4}')
    fi
    if [ "$AVAIL_DISK" -lt 25 ]; then
        warn "Available disk space: ${AVAIL_DISK} GB. The default model alone needs 17 GB."
    else
        success "Disk space: ${AVAIL_DISK} GB available"
    fi

    for tool in curl tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "$tool not found. Please install it first."
            exit 1
        fi
    done
}

###############################################################################
# Install Hermes Agent
###############################################################################
install_hermes() {
    info "Checking Hermes Agent installation..."

    # The official installer links hermes into ~/.local/bin.
    export PATH="$HOME/.local/bin:$PATH"
    if command -v hermes >/dev/null 2>&1; then
        success "Hermes is already installed: $(hermes --version 2>&1 | head -1 || echo 'version unknown')"
        return 0
    fi

    # hermes-agent needs Python 3.11 to 3.13, and `pip install` with the
    # Python 3.9 that ships with macOS finds no version at all (issue #5).
    # The official installer brings its own Python through uv, so the system
    # Python no longer matters. --skip-setup: the llama.cpp provider comes
    # from hermes_config.yaml below, not from the interactive wizard.
    info "Installing Hermes Agent with the official installer (brings its own Python)..."
    if ! curl -fsSL "$HERMES_INSTALLER_URL" | bash -s -- --skip-setup; then
        error "The Hermes Agent installer failed. Log: ~/.hermes/logs/install.log"
        exit 1
    fi
    hash -r
    if ! command -v hermes >/dev/null 2>&1; then
        error "Hermes was installed, but 'hermes' is not on PATH. Open a new terminal and run setup again."
        exit 1
    fi
    success "Hermes Agent installed: $(hermes --version 2>&1 | head -1 || echo 'version unknown')"
}

###############################################################################
# Configure model path
###############################################################################
download_default_model() {
    local dir="${HOME}/.hermes/models"
    local target="${dir}/${DEFAULT_MODEL_LOCAL}"
    mkdir -p "$dir"
    if [ -f "$target" ]; then
        success "Default model already downloaded: $target"
    else
        info "Downloading ${DEFAULT_MODEL_FILE} (about 17 GB) from ${DEFAULT_MODEL_REPO}..."
        # -f keeps an error page from being saved as the model,
        # -C - resumes an interrupted download.
        curl -fL --retry 3 -C - -o "${target}.part" \
            "https://huggingface.co/${DEFAULT_MODEL_REPO}/resolve/main/${DEFAULT_MODEL_FILE}"
        mv "${target}.part" "$target"
        success "Model downloaded to: $target"
    fi
    MODEL_PATH="$target"
}

configure_model() {
    info "Checking model configuration..."

    local current
    current="$(get_model_value path)"
    if [ -n "$current" ] && [ -f "$current" ]; then
        success "Model found at: $current"
        return 0
    fi
    if [ -n "$current" ]; then
        warn "Configured model not found at: $current"
    fi

    MODEL_PATH="${HERMES_SETUP_MODEL:-}"
    if [ -z "$MODEL_PATH" ]; then
        if [ "$NONINTERACTIVE" = "1" ]; then
            MODEL_PATH="skip"
        else
            echo ""
            info "Please provide the path to your GGUF model file."
            echo "   Press Enter to download the default model (${DEFAULT_MODEL_FILE}, about 17 GB)."
            ask MODEL_PATH "Model path: "
            [ -n "$MODEL_PATH" ] || MODEL_PATH="download"
        fi
    fi

    case "$MODEL_PATH" in
        skip)
            warn "No model configured. Set model.path in hermes_config.yaml or run setup again."
            return 0
            ;;
        download)
            download_default_model
            ;;
        *)
            # Accept ~/..., quotes and the backslash-escaped spaces that
            # macOS Terminal inserts when a file is dragged into it.
            MODEL_PATH="$(printf '%s' "$MODEL_PATH" \
                | sed -e "s/^[\"']//" -e "s/[\"']\$//" -e 's/\\ / /g')"
            # The tilde is matched literally on purpose: read does not expand it.
            # shellcheck disable=SC2088
            case "$MODEL_PATH" in
                "~/"*) MODEL_PATH="${HOME}/${MODEL_PATH#"~/"}" ;;
            esac
            if [ ! -f "$MODEL_PATH" ]; then
                error "Model file not found at: $MODEL_PATH"
                exit 1
            fi
            MODEL_PATH="$(cd "$(dirname "$MODEL_PATH")" && pwd)/$(basename "$MODEL_PATH")"
            ;;
    esac

    set_model_value path "$MODEL_PATH"
    success "Model path updated in hermes_config.yaml"
}

###############################################################################
# Detect GPU
###############################################################################
detect_gpu() {
    GPU_KIND="none"
    if [ "$IS_MACOS" = "1" ]; then
        if [ "$ARCH" = "arm64" ]; then
            GPU_KIND="apple"
        fi
    elif command -v nvidia-smi >/dev/null 2>&1; then
        GPU_KIND="nvidia"
    elif [ -e /dev/kfd ] || lsmod 2>/dev/null | grep -q amdgpu; then
        GPU_KIND="amd"
    fi

    case "$GPU_KIND" in
        apple)  success "Apple Silicon detected, llama.cpp will use Metal" ;;
        nvidia) success "NVIDIA GPU detected" ;;
        amd)    success "AMD GPU detected" ;;
        *)      warn "No GPU detected, llama.cpp will run on the CPU (slower but works)" ;;
    esac
}

# Backend name for a llama-server that was already installed.
default_backend() {
    case "$GPU_KIND" in
        apple)  echo "metal" ;;
        nvidia) echo "cuda" ;;
        amd)    echo "hip" ;;
        *)      echo "cpu" ;;
    esac
}

# Read the library list first: with pipefail, `ldconfig -p | grep -q` can
# report failure when grep exits early and ldconfig gets SIGPIPE.
has_vulkan_loader() {
    local libs
    libs="$(ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null || true)"
    case "$libs" in
        *libvulkan.so.1*) return 0 ;;
    esac
    return 1
}

###############################################################################
# Install llama.cpp
###############################################################################
pick_release_asset() {
    local arch
    if [ "$IS_MACOS" = "1" ]; then
        if [ "$ARCH" = "arm64" ]; then
            ASSET="llama-${LLAMACPP_BUILD}-bin-macos-arm64.tar.gz"; ASSET_BACKEND="metal"
        else
            ASSET="llama-${LLAMACPP_BUILD}-bin-macos-x64.tar.gz"; ASSET_BACKEND="cpu"
        fi
        return 0
    fi

    case "$ARCH" in
        x86_64|amd64)  arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) error "No prebuilt llama.cpp for $ARCH. Build it from source: https://github.com/ggml-org/llama.cpp#building-the-project"; exit 1 ;;
    esac

    # One build for AMD and NVIDIA: Vulkan only needs the GPU driver, while
    # the ROCm and CUDA builds need a matching toolkit installed.
    if [ "$GPU_KIND" != "none" ] && has_vulkan_loader; then
        ASSET="llama-${LLAMACPP_BUILD}-bin-ubuntu-vulkan-${arch}.tar.gz"; ASSET_BACKEND="vulkan"
    else
        if [ "$GPU_KIND" != "none" ]; then
            warn "GPU found but no Vulkan loader (libvulkan.so.1), installing the CPU build."
            warn "For GPU speed install Vulkan (e.g. sudo apt install libvulkan1 mesa-vulkan-drivers) and run setup again."
        fi
        ASSET="llama-${LLAMACPP_BUILD}-bin-ubuntu-${arch}.tar.gz"; ASSET_BACKEND="cpu"
    fi
}

install_llamacpp() {
    info "Checking llama.cpp..."
    local llama_dir="${REPO_DIR}/tools/llama.cpp/current"

    if command -v llama-server >/dev/null 2>&1; then
        success "llama-server found: $(command -v llama-server)"
        BACKEND="$(default_backend)"
        return 0
    fi
    if [ -x "${llama_dir}/llama-server" ]; then
        success "llama-server found: ${llama_dir}/llama-server"
        BACKEND="$(cat "${llama_dir}/.backend" 2>/dev/null || default_backend)"
        return 0
    fi

    local src="${HERMES_LLAMACPP_SOURCE:-}"
    if [ -z "$src" ]; then
        if [ "$IS_MACOS" = "1" ] && command -v brew >/dev/null 2>&1; then
            src="brew"
        else
            src="release"
        fi
    fi

    if [ "$src" = "brew" ]; then
        info "Installing llama.cpp with Homebrew..."
        brew install llama.cpp
        BACKEND="$(default_backend)"
        success "llama.cpp installed: $(command -v llama-server)"
        return 0
    fi

    pick_release_asset
    local url="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_BUILD}/${ASSET}"
    local tmp
    tmp="$(mktemp -d)"
    info "Downloading llama.cpp ${LLAMACPP_BUILD} (${ASSET})..."
    curl -fL --retry 3 -o "${tmp}/llama.tar.gz" "$url"
    rm -rf "$llama_dir"
    mkdir -p "$llama_dir"
    tar -xzf "${tmp}/llama.tar.gz" -C "$llama_dir" --strip-components 1
    rm -rf "$tmp"

    if [ ! -x "${llama_dir}/llama-server" ]; then
        error "llama-server is missing from ${ASSET}"
        exit 1
    fi
    if ! "${llama_dir}/llama-server" --version >/dev/null 2>&1; then
        error "llama-server does not start. Output:"
        "${llama_dir}/llama-server" --version >&2 || true
        if [ "$IS_LINUX" = "1" ]; then
            error "Missing system libraries? On Ubuntu/Debian try: sudo apt install libgomp1 libcurl4"
        fi
        exit 1
    fi
    echo "$ASSET_BACKEND" > "${llama_dir}/.backend"
    BACKEND="$ASSET_BACKEND"
    success "llama.cpp installed to ${llama_dir} (${BACKEND})"
}

###############################################################################
# Write the configuration
###############################################################################
configure_backend() {
    set_model_value backend "$BACKEND"
    success "Backend set to '${BACKEND}' in hermes_config.yaml"
}

# Hermes reads ~/.hermes/config.yaml, not the file in this repo. Copy it
# there, as hermes_launch.sh does on WSL, and keep the previous one.
configure_hermes() {
    local home="${HERMES_HOME:-$HOME/.hermes}"
    local target="${home}/config.yaml"
    mkdir -p "$home"
    if [ -f "$target" ] && ! cmp -s "$CONFIG_FILE" "$target"; then
        local backup
        backup="${target}.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$target" "$backup"
        info "Previous Hermes config saved as $backup"
    fi
    cp "$CONFIG_FILE" "$target"
    success "Hermes config written to $target (provider: local llama.cpp on port 8080)"
}

###############################################################################
# Main
###############################################################################
main() {
    if ! locate_repo; then
        bootstrap_clone "$@"
    fi
    CONFIG_FILE="${REPO_DIR}/hermes_config.yaml"

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  Hermes Local Stack — Setup             ║"
    echo "║  Run Hermes + Claude Code locally       ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    install_hermes
    configure_model
    detect_gpu
    install_llamacpp
    configure_backend
    configure_hermes

    echo ""
    success "Setup complete!"
    echo ""
    info "To start Hermes, run:"
    echo "  cd \"${REPO_DIR}\""
    echo "  make start          # Start Hermes + llama.cpp"
    echo "  make claude-bridge  # Start with Claude Code bridge"
    echo ""
}

main "$@"
