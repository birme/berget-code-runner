#!/usr/bin/env bash
# Refreshes the git token for GitHub-connection-backed agent runs.
# Fetches a fresh token from deploy-manager every 45 minutes and writes it to a
# 0600 file on tmpfs (GIT_TOKEN_FILE). The git credential helper and the gh shim
# read that file. The token is never printed or placed in a URL or git config.
#
# Required env: GIT_TOKEN_REFRESH (per-run nonce), DEPLOY_MANAGER_URL, TASK_ID,
#               RUN_ID, TENANT_ID, GIT_TOKEN_FILE
# Optional env: TOKEN_REFRESH_INTERVAL (seconds, default 2700)
# Usage: token-refresh.sh [--once]
#   --once  perform a single refresh and exit with 0 (token written), 1 (failure,
#           old token kept) or 2 (refresh no longer possible, stop retrying)
set -uo pipefail
umask 077

log() { echo "[GIT-TOKEN] $*"; }

refresh_once() {
  local body_file code reason expires token
  body_file=$(mktemp)
  code=$(curl -s -o "${body_file}" -w '%{http_code}' --max-time 20 \
    -X POST "${DEPLOY_MANAGER_URL%/}/myagents/tasks/${TASK_ID}/github-token" \
    -H "Content-Type: application/json" \
    -H "x-osc-run-nonce: ${GIT_TOKEN_REFRESH}" \
    -d "$(jq -nc --arg r "${RUN_ID}" --arg t "${TENANT_ID}" '{runId:$r, tenantId:$t}')" 2>/dev/null) || code="000"

  case "${code}" in
    200)
      token=$(jq -r '.token // empty' "${body_file}" 2>/dev/null)
      expires=$(jq -r '.expiresAt // empty' "${body_file}" 2>/dev/null)
      if [ -z "${token}" ]; then
        log "refresh failed: 200 response without a token, keeping previous token"
        rm -f "${body_file}"
        return 1
      fi
      # Write atomically so a concurrent git/gh read never sees a partial token
      printf '%s' "${token}" > "${GIT_TOKEN_FILE}.tmp" && mv -f "${GIT_TOKEN_FILE}.tmp" "${GIT_TOKEN_FILE}"
      log "refreshed (expires ${expires:-unknown})"
      rm -f "${body_file}"
      return 0
      ;;
    401)
      log "refresh rejected (401): nonce invalid or expired, stopping refresh"
      rm -f "${body_file}"
      return 2
      ;;
    409)
      reason=$(jq -r '.message // .error // .reason // empty' "${body_file}" 2>/dev/null | head -c 200)
      rm -f "${body_file}"
      if echo "${reason}" | grep -qi "no longer active"; then
        log "run is no longer active, stopping refresh"
        return 2
      fi
      log "refresh failed (409: ${reason:-unknown}), keeping previous token"
      return 1
      ;;
    *)
      reason=$(jq -r '.message // .error // .reason // empty' "${body_file}" 2>/dev/null | head -c 200)
      log "refresh failed (HTTP ${code}${reason:+: ${reason}}), keeping previous token"
      rm -f "${body_file}"
      return 1
      ;;
  esac
}

if [ "${1:-}" = "--once" ]; then
  refresh_once
  exit $?
fi

INTERVAL="${TOKEN_REFRESH_INTERVAL:-2700}"
while true; do
  sleep "${INTERVAL}"
  refresh_once
  [ $? -eq 2 ] && exit 0
done
