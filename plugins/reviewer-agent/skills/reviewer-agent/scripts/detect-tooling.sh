#!/usr/bin/env bash
# detect-tooling.sh — report tool availability, versions, and absolute paths
# as JSON on stdout. Re-derived on every machine; nothing is assumed.
# Exit 0 always (it is a report, not a gate).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need_jq

ver() { "$@" 2>/dev/null | head -n1; }

gh_path="$(ra_path gh)"; gh_authed=false; gh_login=""; gh_scopes=""
if [ -n "$gh_path" ] && gh auth status >/dev/null 2>&1; then
  gh_authed=true
  gh_login="$(gh api user --jq .login 2>/dev/null || echo "")"
  gh_scopes="$(gh auth status 2>&1 | sed -n 's/.*Token scopes: //p' | tr -d "'" | head -n1)"
fi

codex_path="$(ra_path codex)"
docker_path="$(ra_path docker)"; docker_daemon=false
if [ -n "$docker_path" ] && docker version >/dev/null 2>&1; then docker_daemon=true; fi
compose_ok=false
if [ -n "$docker_path" ] && docker compose version >/dev/null 2>&1; then compose_ok=true; fi

jq -n \
  --arg ghp "$gh_path" --arg ghv "$( [ -n "$gh_path" ] && ver gh --version )" \
  --argjson gha "$gh_authed" --arg ghl "$gh_login" --arg ghs "$gh_scopes" \
  --arg cxp "$codex_path" --arg cxv "$( [ -n "$codex_path" ] && ver codex --version )" \
  --arg dkp "$docker_path" --arg dkv "$( [ -n "$docker_path" ] && ver docker --version )" \
  --argjson dkd "$docker_daemon" --argjson cmp "$compose_ok" \
  --arg cmv "$( [ "$compose_ok" = true ] && docker compose version 2>/dev/null | head -n1 )" \
  --arg msp "$(ra_path mise)" --arg msv "$(ra_have mise && ver mise --version)" \
  --arg jqp "$(ra_path jq)" --arg gtp "$(ra_path git)" \
  --arg ndp "$(ra_path node)" --arg pyp "$(ra_path python3)" \
  --arg uvp "$(ra_path uv)" \
'{
  gh:     {present: ($ghp|length>0), path: $ghp, version: $ghv, authed: $gha, login: $ghl, scopes: $ghs},
  codex:  {present: ($cxp|length>0), path: $cxp, version: $cxv},
  docker: {present: ($dkp|length>0), path: $dkp, version: $dkv, daemon: $dkd},
  compose:{present: $cmp, version: $cmv},
  mise:   {present: ($msp|length>0), path: $msp, version: $msv},
  jq:     {present: ($jqp|length>0), path: $jqp},
  git:    {present: ($gtp|length>0), path: $gtp},
  node:   {present: ($ndp|length>0), path: $ndp},
  python3:{present: ($pyp|length>0), path: $pyp},
  uv:     {present: ($uvp|length>0), path: $uvp}
}
| . + {capabilities: {
    can_github: (.gh.present and .gh.authed),
    can_codex: .codex.present,
    can_docker_validate: (.docker.present and .docker.daemon and .compose.present)
  }}'
