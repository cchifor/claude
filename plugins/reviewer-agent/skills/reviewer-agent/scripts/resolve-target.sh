#!/usr/bin/env bash
# resolve-target.sh — turn a single positional GitHub target into the list of
# repos to process. Prints JSON on stdout: {scope, owner, repos:[...]}.
#
#   owner/repo or a repo/pulls URL  -> {scope:"repo",  repos:["owner/repo"]}
#   owner (or https://github.com/owner) -> {scope:"owner", owner:"owner",
#       repos:[ all non-archived source repos under owner you can see ]}
#
# usage: resolve-target.sh <url|owner|owner/repo>
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need jq; ra_need gh
gh auth status >/dev/null 2>&1 || ra_die "resolve-target: gh not authenticated (run: gh auth login)"

ARG="${1:-}"; [ -n "$ARG" ] || ARG="${REVIEWER_AGENT_REPO:-}"
[ -n "$ARG" ] || ra_die "resolve-target: a GitHub URL / owner / owner/repo is required"

slug="$(ra_normalize_slug "$ARG")"

if [[ "$slug" == */* ]]; then
  jq -nc --arg r "$slug" '{scope:"repo", owner:($r|split("/")[0]), repos:[$r]}'
else
  owner="$slug"
  # all non-fork, non-archived repos under the owner the token can see, with open PRs first
  repos="$(gh repo list "$owner" --source --no-archived -L 200 --json nameWithOwner \
            --jq '[ .[].nameWithOwner ]' 2>/dev/null || echo '[]')"
  [ "$repos" != '[]' ] || ra_warn "resolve-target: no source repos found under '$owner' (or no access)"
  jq -nc --arg o "$owner" --argjson repos "$repos" '{scope:"owner", owner:$o, repos:$repos}'
fi
