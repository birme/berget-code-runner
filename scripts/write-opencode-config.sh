#!/usr/bin/env bash
set -euo pipefail

# write-opencode-config.sh — generate ~/.config/opencode/opencode.json defining
# the Berget AI OpenAI-compatible provider. Headless: no interactive login.
#
# Reads:
#   BERGET_API_KEY      (required — validated by entrypoint before this runs)
#   BERGET_BASE_URL     (optional — defaults to https://api.berget.ai/v1)
#   OPENCODE_CONFIG_DIR (optional — defaults to $HOME/.config/opencode)
#
# The API key is injected via OpenCode's {env:BERGET_API_KEY} templating so the
# literal secret is never written to disk. If a future OpenCode build does not
# honor templating at provider init, set EMBED_API_KEY=1 to write the literal
# value instead (file lives only in the ephemeral container, never committed).

CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BERGET_BASE_URL="${BERGET_BASE_URL:-https://api.berget.ai/v1}"

mkdir -p "${CONFIG_DIR}"

if [ "${EMBED_API_KEY:-0}" = "1" ]; then
  API_KEY_VALUE="${BERGET_API_KEY}"
else
  API_KEY_VALUE='{env:BERGET_API_KEY}'
fi

jq -n \
  --arg baseURL "${BERGET_BASE_URL}" \
  --arg apiKey "${API_KEY_VALUE}" \
  '{
    "$schema": "https://opencode.ai/config.json",
    "provider": {
      "berget": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Berget AI",
        "options": {
          "baseURL": $baseURL,
          "apiKey": $apiKey
        },
        "models": {
          "kimi-k2-6":            { "name": "Kimi K2.6 (Berget)" },
          "gemma4":               { "name": "Gemma 4 (Berget)" },
          "mistral-medium-3.5":   { "name": "Mistral Medium 3.5 (Berget)" }
        }
      }
    },
    "model": "berget/kimi-k2-6"
  }' > "${CONFIG_FILE}"

echo "[OPENCODE] Wrote provider config to ${CONFIG_FILE} (provider=berget, default=kimi-k2-6)"
