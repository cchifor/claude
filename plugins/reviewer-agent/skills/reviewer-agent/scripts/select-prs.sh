#!/usr/bin/env bash
# select-prs.sh — list eligible open PRs as a JSON array on stdout, sorted by
# number ascending and capped at max_prs_per_run. Each item carries a trust
# `mode` (full | review-only). Skipped PRs are logged to stderr with a reason
# (no silent skips). Idempotency/lock checks happen later, in pr-state.sh claim.
#
# usage: select-prs.sh --repo OWNER/REPO --config-file CONFIG.json
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need_jq; ra_need gh

REPO=""; CFG=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2 ;;
  --config-file) CFG="$2"; shift 2 ;;
  *) shift ;;
esac; done
[ -n "$REPO" ] || REPO="$(ra_cfg "$CFG" '.repo' '')"
[ -n "$REPO" ] || ra_die "select-prs: --repo (or config.repo) required"
gh auth status >/dev/null 2>&1 || ra_die "select-prs: gh is not authenticated (run: gh auth login)"

authors="$(ra_cfg "$CFG" '.authors_allowlist' '[]')";  [ -n "$authors" ] || authors='[]'
include="$(ra_cfg "$CFG" '.include' '[]')";            [ -n "$include" ] || include='[]'
exclude="$(ra_cfg "$CFG" '.exclude' '[]')";            [ -n "$exclude" ] || exclude='[]'
maxprs="$(ra_cfg "$CFG" '.max_prs_per_run' '5')";      [ -n "$maxprs" ] || maxprs=5
base="$(ra_cfg "$CFG" '.base_branch' '')"

raw="$(gh pr list -R "$REPO" --state open -L 100 \
  --json number,title,headRefName,headRefOid,baseRefName,isCrossRepository,maintainerCanModify,isDraft,author,labels 2>/dev/null || echo '[]')"

# stderr: report skips with reasons ('inc'/'exc' avoid jq's reserved 'include')
printf '%s' "$raw" | jq -r --argjson exc "$exclude" --argjson inc "$include" '
  .[] | (.labels|map(.name)) as $l |
  if   ($l|index("reviewer-agent:paused")) then "skip #\(.number): paused label"
  elif .isDraft then "skip #\(.number): draft"
  elif ($l|index("reviewer-agent:merged")) then "skip #\(.number): already merged by agent"
  elif (($exc|length)>0 and (($l - $exc) != $l)) then "skip #\(.number): matches exclude label"
  elif (($inc|length)>0 and ((($l - ($l - $inc))|length)==0)) then "skip #\(.number): no include label"
  else empty end' >&2 || true

printf '%s' "$raw" | jq \
  --argjson authl "$authors" --argjson inc "$include" --argjson exc "$exclude" --argjson max "$maxprs" --arg base "$base" '
  [ .[] | (.labels|map(.name)) as $l | (.author.login // "") as $a
    | select( ($base|length)==0 or .baseRefName==$base )
    | select( ($l|index("reviewer-agent:paused"))|not )
    | select( .isDraft|not )
    | select( ($l|index("reviewer-agent:merged"))|not )
    | select( ($exc|length)==0 or (($l - $exc) == $l) )
    | select( ($inc|length)==0 or ((($l - ($l - $inc))|length) > 0) )
    | .mode = ( if .isCrossRepository then "review-only"
                elif ($authl|length)>0 and (($authl|index($a))|not) then "review-only"
                else "full" end )
    | {number, title, headRefName, headRefOid, baseRefName,
       isCrossRepository, maintainerCanModify, author:$a, labels:$l, mode} ]
  | sort_by(.number) | .[:$max]'
