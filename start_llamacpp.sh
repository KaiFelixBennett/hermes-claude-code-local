#!/usr/bin/env bash
# Linux/macOS llama.cpp server launcher
# Equivalent to start_llamacpp.ps1 for non-Windows environments.
# Reads model.path, backend, context_length and the speculative settings
# from hermes_config.yaml. Runs on the bash 3.2 that ships with macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/hermes_config.yaml"

# Parse a value from the model: block in hermes_config.yaml
get_model_value() {
    local key="$1"
    awk -v wanted="$key" '
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
    ' "$CONFIG"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

MODEL_PATH="${HERMES_LLAMACPP_MODEL_PATH:-$(get_model_value path)}"
CONTEXT="${HERMES_LLAMACPP_CONTEXT:-$(get_model_value context_length)}"
CONTEXT="${CONTEXT:-65536}"
BACKEND="${HERMES_LLAMACPP_BACKEND:-$(get_model_value backend)}"
BACKEND="$(lower "${BACKEND:-cpu}")"
MODEL_ALIAS="${HERMES_LLAMACPP_ALIAS:-$(get_model_value default)}"
MODEL_ALIAS="${MODEL_ALIAS:-local-model}"
SPEC_TYPE="${HERMES_LLAMACPP_SPEC_TYPE:-$(get_model_value speculative_type)}"
SPEC_TYPE="$(lower "${SPEC_TYPE:-none}")"
SPEC_DRAFT="${HERMES_LLAMACPP_SPEC_DRAFT:-$(get_model_value speculative_draft_tokens)}"
PORT="${HERMES_LLAMACPP_PORT:-8080}"

# Find llama-server binary: PATH (e.g. Homebrew), then the build that
# setup.sh downloads, then a binary placed by hand.
LLAMA_SERVER=""
if command -v llama-server &>/dev/null; then
    LLAMA_SERVER="llama-server"
elif [ -x "${SCRIPT_DIR}/tools/llama.cpp/current/llama-server" ]; then
    LLAMA_SERVER="${SCRIPT_DIR}/tools/llama.cpp/current/llama-server"
elif [ -x "${SCRIPT_DIR}/tools/llama.cpp/llama-server" ]; then
    LLAMA_SERVER="${SCRIPT_DIR}/tools/llama.cpp/llama-server"
else
    echo "[ERROR] llama-server not found in PATH or tools/llama.cpp/"
    echo ""
    echo "  Options:"
    echo "    1) Run ./setup.sh, it downloads a prebuilt llama.cpp"
    echo "    2) macOS: brew install llama.cpp"
    echo "    3) Download a prebuilt binary from https://github.com/ggml-org/llama.cpp/releases"
    echo "       and place it in your PATH or at tools/llama.cpp/llama-server"
    exit 1
fi

if [ -z "$MODEL_PATH" ] || [ ! -f "$MODEL_PATH" ]; then
    echo "[ERROR] GGUF model not found: ${MODEL_PATH:-<not set>}"
    echo "  Set model.path in hermes_config.yaml or export HERMES_LLAMACPP_MODEL_PATH=/path/to/model.gguf"
    exit 1
fi

# GPU offload by backend. "cpu" sets -ngl 0 explicitly, because llama.cpp
# otherwise offloads to any GPU it finds.
EXTRA_ARGS=()
case "$BACKEND" in
    hip|rocm)
        echo "  Backend: ROCm/HIP (AMD GPU)"
        EXTRA_ARGS+=(-ngl 99)
        ;;
    cuda)
        echo "  Backend: CUDA (NVIDIA GPU)"
        EXTRA_ARGS+=(-ngl 99)
        ;;
    vulkan)
        echo "  Backend: Vulkan (cross-vendor GPU)"
        EXTRA_ARGS+=(-ngl 99)
        ;;
    metal)
        echo "  Backend: Metal (Apple Silicon)"
        EXTRA_ARGS+=(-ngl 99)
        ;;
    cpu)
        echo "  Backend: CPU (no GPU offload)"
        echo "  [WARN] CPU-only inference on 27B+ models is very slow. GPU strongly recommended."
        EXTRA_ARGS+=(-ngl 0)
        ;;
    *)
        echo "  [WARN] Unknown backend '${BACKEND}', no GPU offload flags set."
        ;;
esac

# MTP speculative decoding needs MTP layers in the model; llama-server
# refuses to start when they are missing. So it is only switched on for
# files with "mtp" in the name, unless HERMES_LLAMACPP_SPEC_TYPE forces it.
MODEL_FILE_LC="$(lower "$(basename "$MODEL_PATH")")"
if [ "$SPEC_TYPE" = "draft-mtp" ] && [ -z "${HERMES_LLAMACPP_SPEC_TYPE:-}" ]; then
    case "$MODEL_FILE_LC" in
        *mtp*) ;;
        *)
            echo "  [INFO] Model file has no 'mtp' in its name, MTP speculative decoding off."
            echo "         Force it with HERMES_LLAMACPP_SPEC_TYPE=draft-mtp"
            SPEC_TYPE="none"
            ;;
    esac
fi
if [ "$SPEC_TYPE" != "none" ] && [ -n "$SPEC_TYPE" ]; then
    EXTRA_ARGS+=(--spec-type "$SPEC_TYPE")
    if [ -n "$SPEC_DRAFT" ]; then
        EXTRA_ARGS+=(--spec-draft-n-max "$SPEC_DRAFT")
    fi
    echo "  Speculative: ${SPEC_TYPE}${SPEC_DRAFT:+, up to ${SPEC_DRAFT} draft tokens}"
fi

echo ""
echo "  Model  : $MODEL_PATH"
echo "  Alias  : $MODEL_ALIAS"
echo "  Context: $CONTEXT"
echo "  Port   : $PORT"
echo ""

# ${EXTRA_ARGS[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
exec "$LLAMA_SERVER" \
    --model "$MODEL_PATH" \
    --alias "$MODEL_ALIAS" \
    --ctx-size "$CONTEXT" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --flash-attn on \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
