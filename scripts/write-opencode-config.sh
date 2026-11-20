#!/usr/bin/env bash
set -euo pipefail

# write-opencode-config.sh — generate ~/.config/opencode/opencode.json defining
# the Berget AI OpenAI-compatible provider. Headless: no interactive login.
#
# Reads:
#   BERGET_API_KEY      (required — validated by entrypoint before this runs)
#   BERGET_BASE_URL     (optional — defaults to https://api.berget.ai/v1)
#   OPENCODE_CONFIG_DIR (optional — defaults to $HOME/.config/opencode)
#   MODEL_ID            (optional — Berget model id, without the "berget/" prefix.
#                        Added to the provider's model list if it is not a known
#                        one, so any model Berget serves can be selected.)
#
# The API key is injected via OpenCode's {env:BERGET_API_KEY} templating so the
# literal secret is never written to disk. If a future OpenCode build does not
# honor templating at provider init, set EMBED_API_KEY=1 to write the literal
# value instead (file lives only in the ephemeral container, never committed).

CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BERGET_BASE_URL="${BERGET_BASE_URL:-https://api.berget.ai/v1}"
DEFAULT_MODEL_ID="google/gemma-4-31B-it"
MODEL_ID="${MODEL_ID:-${DEFAULT_MODEL_ID}}"

mkdir -p "${CONFIG_DIR}"

if [ "${EMBED_API_KEY:-0}" = "1" ]; then
  API_KEY_VALUE="${BERGET_API_KEY}"
else
  API_KEY_VALUE='{env:BERGET_API_KEY}'
fi

jq -n \
  --arg baseURL "${BERGET_BASE_URL}" \
  --arg apiKey "${API_KEY_VALUE}" \
  --arg modelId "${MODEL_ID}" \
  '{
    "$schema": "https://opencode.ai/config.json",
    "autoupdate": false,
    "provider": {
      "berget": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Berget AI",
        "options": {
          "baseURL": $baseURL,
          "apiKey": $apiKey
        },
        "models": ({
          "moonshotai/Kimi-K3.1-Pro":                    { "name": "Kimi K3.1 Pro (Berget)" },
          "zai-org/GLM-5.3-Flash":                       { "name": "GLM 5.3 Flash (Berget)" },
          "google/gemma-4-31B-it":                       { "name": "Gemma 4 31B (Berget)" },
          "mistralai/Mistral-Small-3.2-24B-Instruct-2506": { "name": "Mistral Small 3.2 (Berget)" }
        } + { ($modelId): { "name": ($modelId + " (Berget)") } })
      }
    },
    "model": ("berget/" + $modelId)
  }' > "${CONFIG_FILE}"

echo "[OPENCODE] Wrote provider config to ${CONFIG_FILE} (provider=berget, model=${MODEL_ID})"
