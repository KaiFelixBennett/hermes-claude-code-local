#!/bin/bash
# Hermes Gateway launcher (Telegram + other platforms)
# llama.cpp/OpenAI-compatible server on localhost:8080

set -e

CONFIG="/root/.hermes/config.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONFIG="${HERMES_LOCAL_CONFIG:-${SCRIPT_DIR}/hermes_config.yaml}"

# Mirror the fresh config from the repository
if [ -f "$LOCAL_CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    cp "$LOCAL_CONFIG" "$CONFIG"
fi

API_BASE_URL="http://127.0.0.1:8080/v1"
MODEL_NAME="Gemma-4-31B-it GGUF"

echo -n "llama.cpp check (${API_BASE_URL}): "
if curl -s --connect-timeout 3 "${API_BASE_URL}/models" > /dev/null 2>&1; then
    echo "OK"
else
    echo "UNREACHABLE"
    echo ""
    echo "Please start llama.cpp as an OpenAI-compatible server."
    echo "Recommended: --alias \"${MODEL_NAME}\" --ctx-size 65536"
    exit 1
fi

echo "========================================"
echo "  Hermes Gateway (Telegram Integration)"
echo "  Model: ${MODEL_NAME}"
echo "========================================"
echo ""

cd /root/.hermes/hermes-agent
source venv/bin/activate
exec hermes gateway
