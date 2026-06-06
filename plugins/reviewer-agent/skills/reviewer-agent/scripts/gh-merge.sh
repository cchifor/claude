#!/usr/bin/env bash
# gh-merge.sh — the ONLY allowlisted merge entrypoint. Decides between GitHub
# native auto-merge (where the repo supports it) and a gated direct merge, and
# REFUSES to merge unsafe states. Never uses --admin / --force. Takes a single
# checks snapshot (no blocking polls) — when checks are pending it returns
# {action:"defer"} so the loop/cron re-checks later.
#
# Safety gates before any merge:
#   - head SHA must still equal the validated SHA (else abort: head-moved)
#   - PR must be MERGEABLE (UNKNOWN -> defer; CONFLICTING -> abort)
#   - NO failing checks on the head SHA
#   - NO pending checks (else defer)
#   - if there are ZERO checks at all -> escalate unless allow_no_checks=true
#     (this closes the "required checks are vacuous on an unprotected repo" hole)
#   - if expected_checks given, each must be present AND passing
#
# usage: gh-merge.sh --repo R --pr N --sha S --config-file CONFIG.json
#                    [--method squash|merge|rebase] [--policy auto|escalate]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need jq; ra_need gh
ra_reject_forbidden "$@"

REPO=""; PR=""; SHA=""; CFG=""; METHOD=""; POLICY=""; VERDICT=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2 ;;
  --pr) PR="$2"; shift 2 ;;
  --sha) SHA="$2"; shift 2 ;;
  --config-file) CFG="$2"; shift 2 ;;
  --method) METHOD="$2"; shift 2 ;;
  --policy) POLICY="$2"; shift 2 ;;
  --verdict-file) VERDICT="$2"; shift 2 ;;
  *) shift ;;
esac; done
[ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || ra_die "gh-merge: --repo --pr --sha required"
[ -n "$METHOD" ] || METHOD="$(ra_cfg "$CFG" '.merge_method' 'squash')"
[ -n "$POLICY" ] || POLICY="$(ra_cfg "$CFG" '.merge_policy' 'auto')"
case "$METHOD" in squash|merge|rebase) ;; *) ra_die "invalid merge method: $METHOD" ;; esac
ALLOW_NO_CHECKS="$(ra_cfg "$CFG" '.allow_no_checks' 'false')"
EXPECTED="$(ra_cfg "$CFG" '.expected_checks' '[]')"; [ -n "$EXPECTED" ] || EXPECTED='[]'
DELETE="$(ra_cfg "$CFG" '.delete_branch' 'false')"

out() { jq -nc "$@"; exit 0; }

# a malformed expected_checks (scalar instead of array) must NOT silently
# disable the gate — fail closed.
jq -e 'type=="array"' <<<"$EXPECTED" >/dev/null 2>&1 || out --arg e "$EXPECTED" \
  '{action:"escalate", reason:"bad-expected-checks-config", value:$e}'

V="$(gh pr view "$PR" -R "$REPO" --json headRefOid,mergeable,mergeStateStatus,baseRefName,statusCheckRollup,isCrossRepository 2>/dev/null)" \
  || ra_die "gh pr view failed"
cur_sha="$(jq -r '.headRefOid' <<<"$V")"
mergeable="$(jq -r '.mergeable' <<<"$V")"
base="$(jq -r '.baseRefName' <<<"$V")"
crossrepo="$(jq -r '.isCrossRepository' <<<"$V")"

# 0. head-moved guard
[ "$cur_sha" = "$SHA" ] || out --arg c "$cur_sha" --arg s "$SHA" \
  '{action:"abort", reason:"head-moved", expected:$s, current:$c}'

# 0b. fork guard — forks are review-only, never merged
[ "$crossrepo" = true ] && out '{action:"escalate", reason:"fork-not-merged", detail:"fork PRs are review-only"}'

# 0c. base-branch guard
exp_base="$(ra_cfg "$CFG" '.base_branch' '')"
[ -n "$exp_base" ] && [ "$base" != "$exp_base" ] && out --arg b "$base" --arg e "$exp_base" \
  '{action:"abort", reason:"wrong-base", base:$b, expected:$e}'

# 0d. VERDICT enforcement — the boundary refuses to merge without proof the
# orchestration validated this exact SHA (green), Codex converged, and full mode.
if [ -n "$VERDICT" ] && [ -f "$VERDICT" ]; then
  vres="$(jq -r '.validation.result // ""' "$VERDICT")"
  vconv="$(jq -r '.codex.converged // false' "$VERDICT")"
  vmode="$(jq -r '.mode // ""' "$VERDICT")"         # no fallback: missing mode fails closed
  vsha="$(jq -r '.validated_sha // ""' "$VERDICT")"  # no fallback: missing sha fails closed
  [ "$vmode" = full ] || out --arg m "$vmode" '{action:"escalate", reason:"not-full-mode", mode:$m}'
  [ "$vres" = green ] || out --arg r "$vres" '{action:"escalate", reason:"validation-not-green", validation:$r}'
  [ "$vconv" = true ] || out '{action:"escalate", reason:"codex-not-converged"}'
  { [ -n "$vsha" ] && [ "$vsha" = "$SHA" ]; } || out --arg v "$vsha" --arg s "$SHA" \
    '{action:"escalate", reason:"verdict-sha-mismatch", verdict_sha:$v, sha:$s}'
else
  out '{action:"escalate", reason:"no-verdict", detail:"gh-merge requires --verdict-file proving validation green + codex converged + full mode + matching validated_sha"}'
fi

# 1. mergeability
case "$mergeable" in
  CONFLICTING) out '{action:"abort", reason:"merge-conflict"}' ;;
  UNKNOWN|"") out '{action:"defer", reason:"mergeable-unknown"}' ;;
esac

# 2. classify checks on the head SHA
CHECKS="$(jq -c '
  def cls:
    if .__typename=="CheckRun" then
      (.conclusion as $c | .status as $s |
       if $s!="COMPLETED" then "pending"
       elif ((["SUCCESS","NEUTRAL","SKIPPED"]|index($c))!=null) then "pass"
       else "fail" end)
    elif .__typename=="StatusContext" then
      (.state as $st |
       if ((["PENDING","EXPECTED"]|index($st))!=null) then "pending"
       elif $st=="SUCCESS" then "pass" else "fail" end)
    else "pending" end;
  [ (.statusCheckRollup // [])[]
    | {name:(.name // .context // "?"), state:cls} ]' <<<"$V")"

total="$(jq 'length' <<<"$CHECKS")"
fails="$(jq -c '[.[]|select(.state=="fail")|.name]' <<<"$CHECKS")"
pends="$(jq -c '[.[]|select(.state=="pending")|.name]' <<<"$CHECKS")"
nfail="$(jq 'length' <<<"$fails")"; npend="$(jq 'length' <<<"$pends")"

# 3. expected checks present + passing (if configured)
missing_expected="$(jq -c --argjson exp "$EXPECTED" --argjson c "$CHECKS" -n '
  ([ $c[]|select(.state=="pass")|.name ]) as $pass
  | [ $exp[] as $e | select( ($pass|index($e))==null ) | $e ]')"
nmiss="$(jq 'length' <<<"$missing_expected")"

# 4. decisions
[ "$nfail" -gt 0 ] && out --argjson f "$fails" '{action:"abort", reason:"checks-failing", failing:$f}'
if [ "$total" -eq 0 ]; then
  [ "$ALLOW_NO_CHECKS" = true ] || out '{action:"escalate", reason:"no-checks", detail:"zero status checks on head SHA; refusing to merge without CI signal (set allow_no_checks:true to override)"}'
fi
[ "$npend" -gt 0 ] && out --argjson p "$pends" '{action:"defer", reason:"checks-pending", pending:$p}'
[ "$nmiss" -gt 0 ] && out --argjson m "$missing_expected" '{action:"defer", reason:"expected-check-missing", missing:$m}'

# 5. capability: native auto-merge?
allow_auto="$(gh api "repos/$REPO" --jq '.allow_auto_merge' 2>/dev/null || echo false)"

DELARG=""
[ "$DELETE" = true ] && [ "$crossrepo" = false ] && DELARG="--delete-branch"

if [ "$allow_auto" = true ]; then
  # arm native auto-merge bound to the validated SHA; GitHub gates the merge
  if gh pr merge "$PR" -R "$REPO" --auto "--$METHOD" --match-head-commit "$SHA" $DELARG >&2 2>/dev/null; then
    out --arg m "$METHOD" '{action:"armed", method:$m, capability:"native-auto-merge"}'
  else
    out '{action:"escalate", reason:"arm-failed", detail:"gh pr merge --auto rejected"}'
  fi
fi

# 6. no native capability -> gated direct merge (policy) — checks already green here
if [ "$POLICY" = escalate ]; then
  out '{action:"escalate", reason:"native-auto-merge-unavailable", detail:"merge_policy=escalate; not merging directly"}'
fi
# policy=auto: direct merge of an all-green, mergeable, validated head (no --admin)
if gh pr merge "$PR" -R "$REPO" "--$METHOD" --match-head-commit "$SHA" $DELARG >&2; then
  out --arg m "$METHOD" --argjson n "$total" '{action:"merged", method:$m, capability:"direct", checks_green:$n}'
else
  out '{action:"escalate", reason:"direct-merge-failed"}'
fi
