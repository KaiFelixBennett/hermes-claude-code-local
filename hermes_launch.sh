#!/bin/bash
# Hermes Agent launcher (interactive CLI mode)
# Started by start_hermes.bat in the main terminal window.
# Requirement: WSL2 with mirrored networking (see ~/.wslconfig on host)
# -> llama.cpp/OpenAI-compatible server is reachable from inside WSL
#    via the localhost endpoint configured in hermes_config.yaml.

set -e

# ~/.hermes is /root/.hermes for the root user in WSL, as before.
HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="${HERMES_DIR}/config.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONFIG="${HERMES_LOCAL_CONFIG:-${SCRIPT_DIR}/hermes_config.yaml}"

configure_claude_code_bridge() {
    local enabled="${HERMES_CLAUDE_USE_LITELLM:-0}"

    case "${enabled}" in
        1|true|TRUE|yes|YES|on|ON)
            ;;
        *)
            return 0
            ;;
    esac

    local bridge_url="${HERMES_CLAUDE_BASE_URL:-http://127.0.0.1:4000}"
    local bridge_token="${HERMES_CLAUDE_AUTH_TOKEN:-sk-hermes-local}"
    local bridge_model="${HERMES_CLAUDE_MODEL:-qwen-local-anthropic}"

    bridge_url="${bridge_url%/}"

    echo -n "LiteLLM check (${bridge_url}): "
    if curl -s --connect-timeout 3 -H "Authorization: Bearer ${bridge_token}" "${bridge_url}/v1/models" > /dev/null 2>&1; then
        echo "OK"
    else
        echo "UNREACHABLE"
        echo ""
        echo "Please start LiteLLM locally before using Hermes Claude Code through the local gateway."
        exit 1
    fi

    export ANTHROPIC_BASE_URL="${bridge_url}"
    export ANTHROPIC_AUTH_TOKEN="${bridge_token}"
    export ANTHROPIC_MODEL="${bridge_model}"
    export ANTHROPIC_CUSTOM_MODEL_OPTION="${bridge_model}"

    echo "Claude Code Gateway: ${ANTHROPIC_MODEL} via ${ANTHROPIC_BASE_URL}"
    echo ""
}

extract_model_value() {
    local key="$1"

    awk -v wanted="$key" '
        /^model:[[:space:]]*$/ { in_model=1; next }
        in_model && /^[^[:space:]]/ { in_model=0 }
        in_model && $1 == wanted ":" {
            value = $0
            sub(/^[^:]+:[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/^"/, "", value)
            gsub(/"$/, "", value)
            print value
            exit
        }
    ' "$CONFIG"
}

# Mirror the fresh config from the repository
if [ -f "$LOCAL_CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    cp "$LOCAL_CONFIG" "$CONFIG"
fi

API_BASE_URL="$(extract_model_value base_url)"
MODEL_NAME="$(extract_model_value default)"

if [ -z "$API_BASE_URL" ]; then
    API_BASE_URL="http://127.0.0.1:8080/v1"
fi

if [ -z "$MODEL_NAME" ]; then
    MODEL_NAME="Qwen3.6-27B-MTP GGUF"
fi

API_BASE_URL="${API_BASE_URL%/}"

echo -n "llama.cpp check (${API_BASE_URL}): "
# -f: a server that is still loading the model answers 503.
if curl -sf --connect-timeout 3 "${API_BASE_URL}/models" > /dev/null 2>&1; then
    echo "OK"
else
    echo "UNREACHABLE"
    echo ""
    echo "Please start llama.cpp as an OpenAI-compatible server."
    echo "Recommended: --alias \"${MODEL_NAME}\" --ctx-size 98304"
    echo "Also check ~/.wslconfig: networkingMode=mirrored"
    exit 1
fi

echo ""
echo "========================================"
echo "  Hermes Agent (interactive mode)"
echo "  Gateway runs in background window"
echo "  Model: ${MODEL_NAME}"
echo "========================================"
echo ""

configure_claude_code_bridge

# Older WSL setups run Hermes from the venv of a source checkout. The
# official installer puts hermes on PATH in ~/.local/bin instead.
if [ -f "${HERMES_DIR}/hermes-agent/venv/bin/activate" ]; then
    cd "${HERMES_DIR}/hermes-agent"
    # shellcheck disable=SC1091
    source venv/bin/activate
fi
export PATH="$HOME/.local/bin:$PATH"
exec hermes
