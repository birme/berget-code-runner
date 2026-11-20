#!/usr/bin/env bash
# Tests for token-refresh.sh, gh-shim.sh and the git credential helper.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
FAILS=0
PASSES=0
trap '[ -n "${STUB_PID:-}" ] && kill "${STUB_PID}" 2>/dev/null; rm -rf "${TMP}"' EXIT

ok()   { PASSES=$((PASSES+1)); echo "ok   - $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

start_stub() {
  [ -n "${STUB_PID:-}" ] && kill "${STUB_PID}" 2>/dev/null
  STUB_MODE="$1" node "${ROOT}/tests/stub-server.js" > "${TMP}/port" &
  STUB_PID=$!
  disown
  for _ in $(seq 1 50); do [ -s "${TMP}/port" ] && break; sleep 0.1; done
  PORT=$(cat "${TMP}/port")
  export DEPLOY_MANAGER_URL="http://127.0.0.1:${PORT}"
}

export TASK_ID=task1 RUN_ID=run1 TENANT_ID=tenant1 GIT_TOKEN_REFRESH=nonce-123
export GIT_TOKEN_FILE="${TMP}/token"

# --- token-refresh.sh -------------------------------------------------
start_stub ok
printf 'ghs_OLDTOKEN' > "${GIT_TOKEN_FILE}"
OUT=$("${ROOT}/scripts/token-refresh.sh" --once 2>&1); RC=$?
check "refresh success exits 0" '[ ${RC} -eq 0 ]'
check "refresh writes new token" '[ "$(cat "${GIT_TOKEN_FILE}")" = "ghs_FRESHTOKEN" ]'
check "token file is 0600" '[ "$(stat -c %a "${GIT_TOKEN_FILE}" 2>/dev/null || stat -f %Lp "${GIT_TOKEN_FILE}")" = "600" ]'
check "log has no token (success)" '! echo "${OUT}" | grep -q "ghs_"'

start_stub 500
printf 'ghs_OLDTOKEN' > "${GIT_TOKEN_FILE}"
OUT=$("${ROOT}/scripts/token-refresh.sh" --once 2>&1); RC=$?
check "refresh failure exits 1" '[ ${RC} -eq 1 ]'
check "refresh failure keeps old token" '[ "$(cat "${GIT_TOKEN_FILE}")" = "ghs_OLDTOKEN" ]'
check "refresh failure is logged" 'echo "${OUT}" | grep -q "refresh failed"'
check "log has no token (failure)" '! echo "${OUT}" | grep -q "ghs_"'

start_stub 401
OUT=$("${ROOT}/scripts/token-refresh.sh" --once 2>&1); RC=$?
check "401 stops refreshing (exit 2), old token kept" '[ ${RC} -eq 2 ] && [ "$(cat "${GIT_TOKEN_FILE}")" = "ghs_OLDTOKEN" ]'

start_stub inactive
OUT=$("${ROOT}/scripts/token-refresh.sh" --once 2>&1); RC=$?
check "409 run no longer active stops refreshing" '[ ${RC} -eq 2 ]'

kill ${STUB_PID} 2>/dev/null; sleep 0.2
OUT=$("${ROOT}/scripts/token-refresh.sh" --once 2>&1); RC=$?
check "unreachable endpoint is a failure, old token kept" '[ ${RC} -eq 1 ] && [ "$(cat "${GIT_TOKEN_FILE}")" = "ghs_OLDTOKEN" ]'

# loop mode stops on 401 without hanging
start_stub 401
OUT=$(TOKEN_REFRESH_INTERVAL=0 "${ROOT}/scripts/token-refresh.sh" 2>&1); RC=$?
check "loop exits cleanly after 401" '[ ${RC} -eq 0 ]'

# --- gh shim ----------------------------------------------------------
printf '#!/bin/sh\necho "GH_TOKEN=${GH_TOKEN:-<unset>}"\n' > "${TMP}/fakegh"; chmod +x "${TMP}/fakegh"
export REAL_GH="${TMP}/fakegh"
printf 'ghs_FILETOKEN' > "${GIT_TOKEN_FILE}"

OUT=$(GH_TOKEN=pat_PARAMSTORE GH_TOKEN_SOURCE=paramstore sh "${ROOT}/scripts/gh-shim.sh")
check "(a) paramstore GH_TOKEN + connection -> gh sees paramstore value" '[ "${OUT}" = "GH_TOKEN=pat_PARAMSTORE" ]'

OUT=$(env -u GH_TOKEN -u GH_TOKEN_SOURCE sh "${ROOT}/scripts/gh-shim.sh")
check "(b) no paramstore GH_TOKEN + connection -> gh sees file value" '[ "${OUT}" = "GH_TOKEN=ghs_FILETOKEN" ]'

OUT=$(env -u GH_TOKEN -u GH_TOKEN_SOURCE -u GIT_TOKEN_FILE sh "${ROOT}/scripts/gh-shim.sh")
check "(c) neither -> gh environment untouched" '[ "${OUT}" = "GH_TOKEN=<unset>" ]'
OUT=$(GH_TOKEN=preset env -u GH_TOKEN_SOURCE -u GIT_TOKEN_FILE sh "${ROOT}/scripts/gh-shim.sh")
check "(c) neither, preset GH_TOKEN passes through" '[ "${OUT}" = "GH_TOKEN=preset" ]'

# --- credential helper (extracted from entrypoint) ----------------------
sed -n "/<< 'CRED_EOF'/,/^CRED_EOF/p" "${ROOT}/scripts/entrypoint.sh" | sed '1d;$d' > "${TMP}/helper"
chmod +x "${TMP}/helper"
OUT=$(GIT_TOKEN=static_TOKEN GIT_TOKEN_FILE="${GIT_TOKEN_FILE}" "${TMP}/helper" get)
check "helper prefers token file" 'echo "${OUT}" | grep -qx "password=ghs_FILETOKEN"'
OUT=$(GIT_TOKEN=static_TOKEN GIT_TOKEN_FILE="${TMP}/missing" "${TMP}/helper" get)
check "helper falls back to GIT_TOKEN" 'echo "${OUT}" | grep -qx "password=static_TOKEN"'
OUT=$(env -u GIT_TOKEN_FILE GIT_TOKEN=static_TOKEN "${TMP}/helper" get)
check "helper without refresh behaves as before" '[ "${OUT}" = "$(printf "username=x\npassword=static_TOKEN")" ]'

# --- format-stream.js (real OpenCode events captured with --format json) ----
FMT=$(node "${ROOT}/scripts/format-stream.js" < "${ROOT}/tests/fixture-events.jsonl")
check "formatter prints assistant text" 'echo "${FMT}" | grep -qx "Let me look."'
check "formatter prints tool call" 'echo "${FMT}" | grep -q "^\[tool_use\] bash — echo hi"'
check "formatter prints tool result" 'echo "${FMT}" | grep -q "^\[tool_result\] hi"'
check "formatter prints step summary" 'echo "${FMT}" | grep -q "^\[step\] stop"'
check "formatter passes non-JSON through" '[ "$(echo "plain line" | node "${ROOT}/scripts/format-stream.js")" = "plain line" ]'

RED=$(printf '%s\n' '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"env"},"output":"BERGET_API_KEY=sekret-key-12345 ghp_abcdefghijklmnopqrstuv1234 Authorization: Bearer abc.def.ghi123456"}}}' | BERGET_API_KEY=sekret-key-12345 node "${ROOT}/scripts/format-stream.js")
check "formatter redacts env secrets and token patterns" '! echo "${RED}" | grep -qE "sekret-key|ghp_abc|abc.def.ghi" && echo "${RED}" | grep -q REDACTED'

# --- no token in git config / remote URL / logs ----------------------------
export HOME="${TMP}/home"; mkdir -p "${HOME}"
git config --global credential.helper "${TMP}/helper"
git init -q "${TMP}/repo" && git -C "${TMP}/repo" remote add origin https://github.com/acme/a.git
CFG="$(git config --global --list; cat "${TMP}/repo/.git/config"; git -C "${TMP}/repo" remote -v)"
check "no token in git config or remote URL" '! echo "${CFG}" | grep -qE "ghs_|static_TOKEN"'
check "entrypoint never embeds a token in URL/insteadOf" '! grep -v "^ *#" "${ROOT}/scripts/entrypoint.sh" | grep -qE "x-access-token|insteadOf|://[^ ]*\$\{?GIT_TOKEN"'

# --- model selection and generated OpenCode config -------------------------
cfg() { OPENCODE_CONFIG_DIR="${TMP}/oc-$1" BERGET_API_KEY=k MODEL_ID="${2:-}" bash -c '[ -n "${MODEL_ID}" ] || unset MODEL_ID; . "${ROOT}/scripts/write-opencode-config.sh"' >/dev/null && cat "${TMP}/oc-$1/opencode.json"; }
export ROOT
C1="$(cfg default)"
check "default model is the current Berget default" '[ "$(echo "${C1}" | jq -r .model)" = "berget/google/gemma-4-31B-it" ]'
check "default config lists no retired model" '! echo "${C1}" | grep -qE "Kimi-K2.6|Medium-3.5"'
C2="$(cfg custom zai-org/GLM-5.3-Flash)"
check "selected model becomes the config model" '[ "$(echo "${C2}" | jq -r .model)" = "berget/zai-org/GLM-5.3-Flash" ]'
C3="$(cfg alias kimi-k3)"
check "an unlisted model id or alias is added to the provider models" 'echo "${C3}" | jq -e ".provider.berget.models[\"kimi-k3\"]" >/dev/null && [ "$(echo "${C3}" | jq -r .model)" = "berget/kimi-k3" ]'
check "config keeps the API key as a template, not a literal" 'echo "${C1}" | grep -q "{env:BERGET_API_KEY}" && ! echo "${C1}" | grep -q "\"apiKey\": \"k\""'
norm() { MODEL="$1" bash -c "$(grep '^MODEL_ID=' "${ROOT}/scripts/entrypoint.sh"); echo \"\${MODEL_ID}\""; }
check "MODEL with a slash is not mistaken for provider/model" '[ "$(norm moonshotai/Kimi-K3.1-Pro)" = "moonshotai/Kimi-K3.1-Pro" ]'
check "an existing berget/ prefix is stripped, not doubled" '[ "$(norm berget/google/gemma-4-31B-it)" = "google/gemma-4-31B-it" ]'
check "entrypoint always passes --model as berget/<id>" 'grep -q "OPENCODE_ARGS+=(\"--model\" \"berget/\${MODEL_ID}\")" "${ROOT}/scripts/entrypoint.sh"'

echo ""
echo "${PASSES} passed, ${FAILS} failed"
[ ${FAILS} -eq 0 ]
