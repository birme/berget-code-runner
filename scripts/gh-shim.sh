#!/bin/sh
# gh shim: exports GH_TOKEN from the refreshed GitHub-connection token file, but
# only when GH_TOKEN was not supplied by the parameter store (the entrypoint
# records that as GH_TOKEN_SOURCE=paramstore). Otherwise gh runs untouched.
if [ "${GH_TOKEN_SOURCE:-}" != "paramstore" ] && [ -n "${GIT_TOKEN_FILE:-}" ] && [ -s "${GIT_TOKEN_FILE}" ]; then
  GH_TOKEN=$(cat "${GIT_TOKEN_FILE}")
  export GH_TOKEN
fi
exec "${REAL_GH:-/usr/bin/gh}" "$@"
