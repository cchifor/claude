#!/usr/bin/env bash
# pr-state.sh — per-PR state on GitHub: one hidden marker comment (authoritative
# JSON) + lifecycle labels. Source of truth lives ON the PR so any machine /
# memory-less cron fire reconstructs where it left off. Implements an advisory
# cross-machine lock (claim + confirm-read + heartbeat + TTL takeover).
#
# subcommands:
#   bootstrap --repo R
#   get       --repo R --pr N
#   claim     --repo R --pr N --sha S [--ttl T] [--worker W]
#   heartbeat --repo R --pr N [--worker W]
#   update    --repo R --pr N --json '<partial>'
#   release   --repo R --pr N --outcome O [--sha S] [--summary-file F]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need_jq; ra_need gh

CMD="${1:-}"; shift || true
REPO=""; PR=""; SHA=""; TTL=""; WORKER=""; JSON=""; OUTCOME=""; SUMMARY_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2 ;;
  --pr) PR="$2"; shift 2 ;;
  --sha) SHA="$2"; shift 2 ;;
  --ttl) TTL="$2"; shift 2 ;;
  --worker) WORKER="$2"; shift 2 ;;
  --json) JSON="$2"; shift 2 ;;
  --outcome) OUTCOME="$2"; shift 2 ;;
  --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
  *) shift ;;
esac; done

[ -n "$WORKER" ] || WORKER="$(ra_worker_id)"
[ -n "$TTL" ] || TTL=3600

# ── comment helpers ──
# Marker comments are only trusted from the authenticated operator's own login —
# a PR commenter cannot spoof state/locks.
ME="$(gh api user --jq .login 2>/dev/null || echo "")"
[ -n "$ME" ] || ra_die "pr-state: cannot determine authenticated gh login (run: gh auth login)"
comment_id() {
  gh api "repos/$REPO/issues/$PR/comments" --paginate \
    --jq "map(select((.user.login==\"$ME\") and (.body | contains(\"reviewer-agent:state\"))))[0].id // empty" 2>/dev/null || true
}
read_marker() {
  local id body
  id="$(comment_id)"
  [ -n "$id" ] || { printf '{}'; return; }
  body="$(gh api "repos/$REPO/issues/comments/$id" --jq .body 2>/dev/null || echo '')"
  printf '%s' "$body" | awk '
    /reviewer-agent:state -->/ {inb=0}
    inb {print}
    /<!-- reviewer-agent:state/ {inb=1}' | jq -c '.' 2>/dev/null || printf '{}'
}
render_body() {  # $1 = marker json -> full comment body on stdout
  local m="$1"
  printf '%s\n' "$RA_MARKER_BEGIN"
  printf '%s\n' "$(jq -c '.' <<<"$m")"
  printf '%s\n\n' "$RA_MARKER_END"
  jq -r '
    "### reviewer-agent — \(.state // "unknown")",
    "- Head processed: `\((.last_processed_head_sha // "n/a")[0:8])`",
    "- Codex: \(.codex.rounds // 0) round(s)" + (if .codex.converged==true then " (converged)" else "" end),
    "- Validation: \(.validation.result // "n/a")" + (if .validation.source then " (\(.validation.source))" else "" end),
    "- Merge: \(.merge.action // "n/a")",
    "- Updated: \(.updated_at // "n/a") by \(.lock.worker // .last_worker // "?")"
    + (if .escalation.reason then "\n- **Escalation:** \(.escalation.reason)" else "" end)
  ' <<<"$m"
}
write_comment() {  # $1 = full body file path
  local id; id="$(comment_id)"
  if [ -n "$id" ]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -F "body=@$1" >/dev/null
  else
    gh pr comment "$PR" -R "$REPO" --body-file "$1" >/dev/null
  fi
}
persist() {  # $1 = marker json ; renders + upserts the single comment
  local f; f="$(ra_scratch_dir "$REPO" "$PR")/comment-body.md"
  render_body "$1" >"$f"
  write_comment "$f"
}

# ── label helpers (REST, not `gh pr edit`) ──
# `gh pr edit --add/remove-label` issues a GraphQL mutation that touches
# projectCards and ERRORS on repos with deprecated Projects-classic. The REST
# issues/labels endpoints don't, so use them.
add_label() { gh api --method POST "repos/$REPO/issues/$PR/labels" -f "labels[]=$1" >/dev/null 2>&1 || true; }
remove_label() {
  local enc; enc="$(jq -rn --arg s "$1" '$s|@uri')"
  gh api -X DELETE "repos/$REPO/issues/$PR/labels/$enc" >/dev/null 2>&1 || true
}
set_primary_label() {  # remove all RA primary labels, add $1
  local keep="$1" l
  for l in "$RA_LABEL_PROCESSING" "$RA_LABEL_FIXED" "$RA_LABEL_MERGED" "$RA_LABEL_REVIEW_ONLY"; do
    [ "$l" = "$keep" ] && continue
    remove_label "$l"
  done
  [ -n "$keep" ] && add_label "$keep"
}

case "$CMD" in
  bootstrap)
    [ -n "$REPO" ] || ra_die "bootstrap: --repo required"
    ensure() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 || true; }
    ensure "$RA_LABEL_PROCESSING"  fbca04 "reviewer-agent is actively working this PR (lock)"
    ensure "$RA_LABEL_FIXED"       0e8a16 "reviewer-agent pushed fixes; awaiting checks/merge"
    ensure "$RA_LABEL_MERGED"      1d76db "reviewer-agent merged (or armed auto-merge for) this PR"
    ensure "$RA_LABEL_REVIEW_ONLY" c5def5 "reviewer-agent review-only (fork/untrusted; not executed/merged)"
    ensure "$RA_LABEL_NEEDS_HUMAN" d73a4a "reviewer-agent escalated; human action required"
    ensure "$RA_LABEL_PAUSED"      5319e7 "KILL-SWITCH — reviewer-agent will not touch this PR"
    echo '{"action":"bootstrapped"}'
    ;;

  get)
    [ -n "$REPO" ] && [ -n "$PR" ] || ra_die "get: --repo and --pr required"
    read_marker
    ;;

  claim)
    [ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || ra_die "claim: --repo --pr --sha required"
    M="$(read_marker)"
    state="$(jq -r '.state // ""' <<<"$M")"
    last="$(jq -r '.last_processed_head_sha // ""' <<<"$M")"
    lworker="$(jq -r '.lock.worker // ""' <<<"$M")"
    lat="$(jq -r '.lock.claimed_at // ""' <<<"$M")"
    lttl="$(jq -r '.lock.ttl_seconds // 0' <<<"$M")"
    # terminal at same head SHA -> already done
    case "$state" in
      merged|review-only|needs-human)
        if [ "$last" = "$SHA" ]; then
          jq -nc --arg s "$state" '{action:"skip", reason:"done", state:$s}'; exit 0
        fi ;;
    esac
    # locked-and-fresh by another worker -> skip
    if [ "$state" = processing ] && [ -n "$lworker" ] && [ "$lworker" != "$WORKER" ] && [ -n "$lat" ]; then
      age=$(( $(ra_epoch) - $(date -u -d "$lat" +%s 2>/dev/null || echo 0) ))
      if [ "$age" -lt "$lttl" ]; then
        jq -nc --arg w "$lworker" --arg a "$age" '{action:"skip", reason:"locked", by:$w, age_seconds:($a|tonumber)}'; exit 0
      fi
    fi
    # claim
    NOW="$(ra_now)"
    NEW="$(jq -c \
      --arg repo "$REPO" --argjson pr "$PR" --arg sha "$SHA" --arg w "$WORKER" \
      --arg now "$NOW" --argjson ttl "$TTL" --arg ver "$RA_VERSION" \
      --arg takeover "$( [ -n "$lworker" ] && [ "$lworker" != "$WORKER" ] && echo "$lworker" || echo "" )" '
      . + {schema:1, repo:$repo, pr:$pr, state:"processing",
           lock:{worker:$w, claimed_at:$now, ttl_seconds:$ttl, claim_sha:$sha},
           updated_at:$now, agent_version:$ver}
      | (if ($takeover|length)>0 then .lock.takeover_from=$takeover else . end)' <<<"$M")"
    persist "$NEW"
    set_primary_label "$RA_LABEL_PROCESSING"
    # confirm-read resolves the residual race (last-writer-wins -> loser yields)
    M2="$(read_marker)"; cw="$(jq -r '.lock.worker // ""' <<<"$M2")"
    if [ "$cw" = "$WORKER" ]; then
      jq -nc '{action:"claimed"}'
    else
      jq -nc --arg w "$cw" '{action:"skip", reason:"lost-race", by:$w}'
    fi
    ;;

  heartbeat)
    [ -n "$REPO" ] && [ -n "$PR" ] || ra_die "heartbeat: --repo --pr required"
    M="$(read_marker)"; lw="$(jq -r '.lock.worker // ""' <<<"$M")"
    if [ "$lw" = "$WORKER" ]; then
      persist "$(jq -c --arg now "$(ra_now)" '.lock.claimed_at=$now | .updated_at=$now' <<<"$M")"
      jq -nc '{action:"heartbeat-ok"}'
    else
      jq -nc --arg w "$lw" '{action:"heartbeat-skipped", reason:"not-owner", owner:$w}'
    fi
    ;;

  update)
    [ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$JSON" ] || ra_die "update: --repo --pr --json required"
    M="$(read_marker)"
    lw="$(jq -r '.lock.worker // ""' <<<"$M")"
    if [ "$lw" != "$WORKER" ]; then   # fail closed: must hold the lock to mutate
      jq -nc --arg w "$lw" '{action:"skipped", reason:(if ($w|length)>0 then "not-owner" else "no-lock" end), owner:$w}'; exit 0
    fi
    persist "$(jq -c --argjson p "$JSON" --arg now "$(ra_now)" '. * $p | .updated_at=$now' <<<"$M")"
    jq -nc '{action:"updated"}'
    ;;

  release)
    [ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$OUTCOME" ] || ra_die "release: --repo --pr --outcome required"
    M="$(read_marker)"
    lw="$(jq -r '.lock.worker // ""' <<<"$M")"
    if [ "$lw" != "$WORKER" ]; then   # fail closed: only the lock holder may release
      jq -nc --arg w "$lw" '{action:"skipped", reason:(if ($w|length)>0 then "not-owner" else "no-lock" end), owner:$w}'; exit 0
    fi
    NOW="$(ra_now)"
    NEW="$(jq -c --arg o "$OUTCOME" --arg now "$NOW" --arg sha "$SHA" --arg lw "$lw" '
      . + {state:$o, updated_at:$now, last_worker:(.lock.worker // $lw)}
      | (if ($sha|length)>0 then .last_processed_head_sha=$sha else . end)
      | del(.lock)' <<<"$M")"
    if [ -n "$SUMMARY_FILE" ] && [ -f "$SUMMARY_FILE" ]; then
      f="$(ra_scratch_dir "$REPO" "$PR")/comment-body.md"
      render_body "$NEW" >"$f"; printf '\n' >>"$f"; cat "$SUMMARY_FILE" >>"$f"
      write_comment "$f"
    else
      persist "$NEW"
    fi
    case "$OUTCOME" in
      merged) set_primary_label "$RA_LABEL_MERGED" ;;
      fixed) set_primary_label "$RA_LABEL_FIXED" ;;
      review-only) set_primary_label "$RA_LABEL_REVIEW_ONLY"; add_label "$RA_LABEL_NEEDS_HUMAN" ;;
      needs-human) set_primary_label ""; add_label "$RA_LABEL_NEEDS_HUMAN" ;;
    esac
    jq -nc --arg o "$OUTCOME" '{action:"released", outcome:$o}'
    ;;

  *) ra_die "unknown subcommand: '$CMD' (bootstrap|get|claim|heartbeat|update|release)" ;;
esac
