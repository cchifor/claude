#!/usr/bin/env bash
# resolve-config.sh — merge configuration from four sources and print the
# effective config as JSON on stdout.
#
#   precedence (low -> high):
#     built-in defaults  <  base-branch .reviewer-agent.yml  <  REVIEWER_AGENT_* env  <  CLI flags
#
# CRITICAL: the repo config is read from the TRUSTED BASE BRANCH via the GitHub
# API (ref=<base>), never from a PR checkout. A PR that changes config cannot
# influence the agent's own behaviour.
#
# usage: resolve-config.sh --repo OWNER/REPO [--base-branch B] [--<key> <val> ...]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need_jq

# coerce a raw string into a JSON scalar/array literal
to_json_val() {
  local v="$1" inner
  case "$v" in
    true|false) printf '%s' "$v" ;;
    -[0-9]*|[0-9]*) [[ "$v" =~ ^-?[0-9]+$ ]] && printf '%s' "$v" || jq -Rn --arg s "$v" '$s' ;;
    \[*\])                                      # inline list: [a, b] OR ["a","b"]
      inner="${v#\[}"; inner="${inner%\]}"
      jq -cn --arg s "$inner" \
        '[ $s | split(",")[] | gsub("^\\s+|\\s+$";"") | gsub("^\"+|\"+$";"") | select(length>0) ]'
      ;;
    *) jq -Rn --arg s "$v" '$s' ;;
  esac
}

# ---- 1. built-in defaults ----
DEFAULTS='{
  "repo": "",
  "base_branch": "",
  "local_clone": "",
  "mode": "loop",
  "phase": "merge",
  "dry_run": false,
  "poll_interval": "15m",
  "watch_interval": "60s",
  "merge_policy": "auto",
  "merge_method": "squash",
  "delete_branch": false,
  "trust": "same-repo",
  "authors_allowlist": [],
  "expected_checks": [],
  "allow_no_checks": false,
  "codex_round_cap": 2,
  "validation_cap": 2,
  "validation_cmd": "",
  "validation_level": "slim",
  "include": [],
  "exclude": [],
  "protected_paths": [".github/", "infra/", "CODEOWNERS", "scripts/up.sh", "secrets/", ".reviewer-agent.yml", "docker-compose", "mise.toml"],
  "max_prs_per_run": 50,
  "max_merges_per_run": 50,
  "lock_ttl_seconds": 3600,
  "concurrency": 1
}'

# ---- parse CLI flags into an overrides object (and pull out repo/base early) ----
CLI='{}'; REPO=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --*)
      key="${1#--}"; key="${key//-/_}"; shift
      # boolean flag if nothing follows or the next token is another --flag
      if [ $# -eq 0 ] || [[ "${1:-}" == --* ]]; then val=true; else val="$1"; shift; fi
      [ "$key" = repo ] && REPO="$val"
      [ "$key" = base_branch ] && BASE="$val"
      CLI="$(jq --arg k "$key" --argjson v "$(to_json_val "$val")" '. + {($k): $v}' <<<"$CLI")"
      ;;
    *) shift ;;
  esac
done
[ -n "$REPO" ] || REPO="${REVIEWER_AGENT_REPO:-}"
# accept a URL / owner-repo and normalize to owner/repo
[ -n "$REPO" ] && REPO="$(ra_normalize_slug "$REPO")"

# ---- 2. base-branch .reviewer-agent.yml (trusted provenance) ----
FILECFG='{}'
if [ -n "$REPO" ] && ra_have gh && gh auth status >/dev/null 2>&1; then
  [ -n "$BASE" ] || BASE="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")"
  if [ -n "$BASE" ]; then
    raw="$(gh api "repos/$REPO/contents/.reviewer-agent.yml?ref=$BASE" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -n "$raw" ]; then
      # minimal flat YAML: `key: scalar` and `key: [a, b]`. Block lists unsupported (use inline).
      while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*:[[:space:]]*(.*)$ ]] || continue
        k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        v="${v%"${v##*[![:space:]]}"}"          # rstrip
        v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"   # strip quotes
        [ -z "$v" ] && continue                 # skip block-list parents (unsupported)
        FILECFG="$(jq --arg k "$k" --argjson v "$(to_json_val "$v")" '. + {($k): $v}' <<<"$FILECFG")"
      done <<<"$raw"
    fi
  fi
fi

# ---- 3. REVIEWER_AGENT_* env overrides ----
ENVCFG='{}'
while IFS='=' read -r name value; do
  case "$name" in
    REVIEWER_AGENT_*)
      k="$(printf '%s' "${name#REVIEWER_AGENT_}" | tr '[:upper:]' '[:lower:]')"
      ENVCFG="$(jq --arg k "$k" --argjson v "$(to_json_val "$value")" '. + {($k): $v}' <<<"$ENVCFG")"
      ;;
  esac
done < <(env)

# ---- merge: defaults * file * env * cli (later wins) ----
jq -n \
  --argjson d "$DEFAULTS" --argjson f "$FILECFG" --argjson e "$ENVCFG" --argjson c "$CLI" \
  --arg base "$BASE" --arg repo "$REPO" \
  '($d * $f * $e * $c)
   | (if ($repo|length)>0 then .repo=$repo else . end)
   | (if (.base_branch|length)==0 and ($base|length)>0 then .base_branch=$base else . end)
   | . + {_meta: {version: "'"$RA_VERSION"'"}}'
