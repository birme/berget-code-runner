#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# berget-code-runner — Run a headless OpenCode session backed by
# Berget AI (sovereign-cloud, OpenAI-compatible) against a git repo.
# ============================================================

# --- 0. Fix volume ownership (runs as root, then drops to node) ---
if [ "$(id -u)" = "0" ]; then
  chown -R node:node /usercontent
  exec runuser -u node -- "$0" "$@"
fi

echo "=== berget-code-runner ==="
echo "Starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# --- 1. Validate required environment variables ---
if [ -z "${BERGET_API_KEY:-}" ]; then
  echo "ERROR: BERGET_API_KEY must be set (Berget AI API key)" >&2
  exit 1
fi

SOURCE_URL="${SOURCE_URL:-${GITHUB_URL:-}}"
if [ -z "${SOURCE_URL}" ]; then
  echo "ERROR: SOURCE_URL (or GITHUB_URL) is required — the git repository to clone" >&2
  exit 1
fi

PROMPT="${PROMPT:?PROMPT env var is required — the task for the agent to perform}"

MODEL="${MODEL:-}"
# OpenCode addresses models as <provider>/<model>. A Berget model id such as
# "google/gemma-4-31B-it" has a slash of its own, so it must always be given
# as "berget/<id>"; an id that already carries the prefix is accepted as is.
MODEL_ID="${MODEL#berget/}"
export MODEL_ID
MAX_TURNS="${MAX_TURNS:-}"
ALLOWEDTOOLS="${ALLOWEDTOOLS:-}"
DISALLOWEDTOOLS="${DISALLOWEDTOOLS:-}"
SUB_PATH="${SUB_PATH:-}"
BERGET_BASE_URL="${BERGET_BASE_URL:-https://api.berget.ai/v1}"

echo "Source:      ${SOURCE_URL}"
echo "Model:       ${MODEL_ID:-<default: google/gemma-4-31B-it>}"
echo "Max turns:   ${MAX_TURNS:-<unlimited>}"
echo "Sub path:    ${SUB_PATH:-<root>}"
echo "Berget URL:  ${BERGET_BASE_URL}"
echo "===================="

# --- 2. Clone the repository ---
WORK_DIR="/usercontent"

BRANCH="${GIT_BRANCH:-}"
if [[ "${SOURCE_URL}" == *"#"* ]]; then
  BRANCH="${SOURCE_URL##*#}"
  SOURCE_URL="${SOURCE_URL%%#*}"
fi

export GIT_TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"

# Token file for GitHub-connection refresh (see token-refresh.sh). Lives on tmpfs when
# available. The credential helper prefers this file over GIT_TOKEN when it exists.
TOKEN_REFRESH_ENABLED=0
if [ -n "${GIT_TOKEN_REFRESH:-}" ] && [ -n "${DEPLOY_MANAGER_URL:-}" ]; then
  TOKEN_REFRESH_ENABLED=1
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    TOKEN_DIR=$(mktemp -d /dev/shm/git-token.XXXXXX)
  else
    TOKEN_DIR=$(mktemp -d)
  fi
  chmod 700 "${TOKEN_DIR}"
  export GIT_TOKEN_FILE="${TOKEN_DIR}/token"
  # Seed with the token the run started with so gh sees it before the first refresh
  if [ -n "${GIT_TOKEN}" ]; then
    (umask 077; printf '%s' "${GIT_TOKEN}" > "${GIT_TOKEN_FILE}")
  fi
fi

# Set up git credential helper — never embed the token in the remote URL or git config.
# The helper script reads the refreshed token file (when present) or GIT_TOKEN from the
# environment at authentication time, so "git remote -v" and "git config --list" cannot
# leak the token.
if [ -n "${GIT_TOKEN}" ] || [ "${TOKEN_REFRESH_ENABLED}" = "1" ]; then
  GIT_CRED_HELPER=$(mktemp)
  cat > "${GIT_CRED_HELPER}" << 'CRED_EOF'
#!/bin/sh
if [ -n "${GIT_TOKEN_FILE:-}" ] && [ -s "${GIT_TOKEN_FILE}" ]; then
  _token=$(cat "${GIT_TOKEN_FILE}")
else
  _token="${GIT_TOKEN:-}"
fi
echo "username=x"
echo "password=${_token}"
CRED_EOF
  chmod +x "${GIT_CRED_HELPER}"
  git config --global credential.helper "${GIT_CRED_HELPER}"
  echo "Cloning private repository..."
else
  echo "Cloning public repository..."
fi

CLONE_ARGS=("--depth" "1")
if [ -n "${BRANCH}" ]; then
  CLONE_ARGS+=("--branch" "${BRANCH}")
  echo "Branch: ${BRANCH}"
fi

git clone "${CLONE_ARGS[@]}" "${SOURCE_URL}" "${WORK_DIR}" 2>&1
echo "Repository cloned successfully."

if [ -n "${SUB_PATH}" ]; then
  WORK_DIR="${WORK_DIR}/${SUB_PATH}"
  if [ ! -d "${WORK_DIR}" ]; then
    echo "ERROR: SUB_PATH '${SUB_PATH}' does not exist in the repository" >&2
    exit 1
  fi
  echo "Using sub-path: ${SUB_PATH}"
fi

cd "${WORK_DIR}"
echo "Working directory: $(pwd)"

git config user.email "agent@berget.ai"
git config user.name "Berget Agent"
echo "Git identity set: Berget Agent <agent@berget.ai>"

if [ -f "AGENTS.md" ]; then echo "Found AGENTS.md in repository."; fi
if [ -f "CLAUDE.md" ]; then echo "Found CLAUDE.md in repository."; fi
if [ -d ".opencode" ]; then echo "Found .opencode/ directory in repository."; fi

# --- 3. Load environment variables from config service ---
if [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ]; then
  if [ -z "${OSC_ENV:-}" ] && [ -n "${OSC_MCP_URL:-}" ]; then
    _extracted=$(echo "${OSC_MCP_URL}" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    if [ -n "${_extracted}" ]; then OSC_ENV="${_extracted}"; else OSC_ENV="prod"; fi
  fi

  REFRESH_RESULT=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"${OSC_ACCESS_TOKEN}\"}" 2>/dev/null) || true
  if [ -n "${REFRESH_RESULT:-}" ]; then
    FRESH_PAT=$(echo "${REFRESH_RESULT}" | jq -r '.token // empty')
    if [ -n "${FRESH_PAT}" ]; then
      export OSC_ACCESS_TOKEN="${FRESH_PAT}"
      echo "[CONFIG] Refreshed access token via runner refresh token"
    fi
  fi

  echo "[CONFIG] Loading environment variables from config service '${CONFIG_SVC}'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env --env "${OSC_ENV:-prod}" "${CONFIG_SVC}" 2>&1) || true
  config_exit=$?
  if [ ${config_exit} -eq 0 ]; then
    valid_exports=$(echo "${config_env_output}" | grep "^export [A-Za-z_][A-Za-z0-9_]*=" || true)
    if [ -n "${valid_exports}" ]; then
      eval "${valid_exports}"
      var_count=$(echo "${valid_exports}" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded ${var_count} environment variable(s)"
    else
      echo "[CONFIG] WARNING: Config service returned success but no valid export statements."
      echo "[CONFIG] Raw output: ${config_env_output}"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config from '${CONFIG_SVC}' (exit code ${config_exit})."
    echo "[CONFIG] Raw output: ${config_env_output}"
    if echo "${config_env_output}" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Your OSC_ACCESS_TOKEN may have expired. Refresh it and retry."
    fi
  fi
fi

# Record whether GH_TOKEN came from the parameter store. The gh shim only uses the
# GitHub-connection token when this is not "paramstore" (a parameter-store GH_TOKEN
# always takes precedence).
if [ -n "${GH_TOKEN:-}" ]; then
  export GH_TOKEN_SOURCE=paramstore
fi

# Start the background token refresher (GitHub connection, runs longer than 1 h)
if [ "${TOKEN_REFRESH_ENABLED}" = "1" ]; then
  if [ -n "${TASK_ID:-}" ] && [ -n "${RUN_ID:-}" ] && [ -n "${TENANT_ID:-}" ]; then
    /runner/token-refresh.sh &
    echo "[GIT-TOKEN] Background token refresh started (every ${TOKEN_REFRESH_INTERVAL:-2700}s)"
  else
    echo "[GIT-TOKEN] WARNING: GIT_TOKEN_REFRESH set but TASK_ID, RUN_ID or TENANT_ID missing; token will not be refreshed"
  fi
fi

# --- 4. Configure GitHub CLI ---
if [ -n "${GIT_TOKEN}" ]; then
  # The global credential helper (set during clone above) handles subsequent
  # git operations — no url.insteadOf rewrite needed. That pattern embedded the
  # token in ~/.gitconfig, making it visible via "git config --list".
  : # no-op
fi
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null && \
    echo "GitHub CLI authenticated." || \
    echo "GitHub CLI authentication skipped (token may not be a GitHub PAT)."
fi

# --- 5. Generate OpenCode provider config (Berget AI) ---
# NOTE: must run AFTER step 3 so a config-service-provided BERGET_API_KEY is honored.
. /runner/write-opencode-config.sh

# --- 6. Configure OSC MCP server (if token available) ---
if [ -n "${OSC_ACCESS_TOKEN:-}" ]; then
  echo "Configuring OSC MCP server for OpenCode..."
  CONFIG_FILE="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/opencode.json"
  MCP_URL="${OSC_MCP_URL:-https://mcp.osaas.io/mcp}"
  # The token is referenced through OpenCode's {env:...} templating so the literal
  # secret is not written to disk (OSC_ACCESS_TOKEN is exported to the session below).
  export OSC_ACCESS_TOKEN
  tmp=$(mktemp)
  if ! jq --arg url "${MCP_URL}" --arg auth 'Bearer {env:OSC_ACCESS_TOKEN}' \
    '.mcp = ((.mcp // {}) + {
       "OSC": { "type": "remote", "url": $url, "enabled": true,
                "headers": { "Authorization": $auth } }
     })' "${CONFIG_FILE}" > "${tmp}"; then
    echo "ERROR: failed to add the OSC MCP server to ${CONFIG_FILE}" >&2
    exit 1
  fi
  mv "${tmp}" "${CONFIG_FILE}"
  # Verify the server is in the config — fail loudly instead of running without MCP.
  if [ "$(jq -r '.mcp.OSC.url // empty' "${CONFIG_FILE}")" != "${MCP_URL}" ]; then
    echo "ERROR: OSC MCP server registration did not stick in ${CONFIG_FILE}" >&2
    exit 1
  fi
  echo "OSC MCP server configured (${MCP_URL})"
fi

# --- 7. Build the OpenCode command ---
OPENCODE_ARGS=("run" "--dangerously-skip-permissions")

if [ -n "${MODEL_ID}" ]; then
  OPENCODE_ARGS+=("--model" "berget/${MODEL_ID}")
fi

# Stream JSON events by default so tool calls, tool results and intermediate
# turns are visible; format-stream.js turns them into human-readable stdout.
# VERBOSE=0 falls back to plain output (OpenCode's default text format),
# RAW_JSON=1 emits the raw JSONL events without the formatter.
STREAM_JSON_ENABLED=0
if [ "${VERBOSE:-1}" != "0" ] && [ "${VERBOSE:-1}" != "false" ]; then
  OPENCODE_ARGS+=("--format" "json")
  STREAM_JSON_ENABLED=1
elif [ "${RAW_JSON:-0}" = "1" ] || [ "${RAW_JSON:-0}" = "true" ]; then
  OPENCODE_ARGS+=("--format" "json")
fi

if [ -n "${MAX_TURNS}" ]; then
  echo "[WARN] MAX_TURNS=${MAX_TURNS} provided but OpenCode 'run' has no turn-limit flag; ignoring."
fi

if [ -n "${ALLOWEDTOOLS}" ] || [ -n "${DISALLOWEDTOOLS}" ]; then
  echo "[WARN] ALLOWEDTOOLS/DISALLOWEDTOOLS use Claude Code tool names and are not applied by OpenCode; ignoring."
fi

# --- 8. Run the OpenCode session ---
echo ""
echo "=== OpenCode (Berget) session starting ==="
echo "Prompt: ${PROMPT}"
echo "==========================================="
echo ""

export BERGET_API_KEY="${BERGET_API_KEY}"
export OPENCODE_DISABLE_AUTOUPDATE=1

if [ "${STREAM_JSON_ENABLED}" = "1" ] && [ "${RAW_JSON:-0}" != "1" ] && [ "${RAW_JSON:-0}" != "true" ]; then
  set +e
  opencode "${OPENCODE_ARGS[@]}" "${PROMPT}" | node /runner/format-stream.js
  EXIT_CODE=${PIPESTATUS[0]}
  set -e
else
  set +e
  opencode "${OPENCODE_ARGS[@]}" "${PROMPT}"
  EXIT_CODE=$?
  set -e
fi

echo ""
echo "=== OpenCode session ended ==="
echo "Exit code: ${EXIT_CODE}"
echo "Finished at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

exit ${EXIT_CODE}
