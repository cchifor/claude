#!/usr/bin/env bash
# git-ops.sh — the ONLY allowlisted git-mutation entrypoint. Takes structured
# args and constructs a safe git command; never forwards arbitrary flags.
# Force-push / --no-verify / --amend etc. are rejected (defence-in-depth: the
# allowlist glob is not a boundary). All pushes are fast-forward, hooks run.
#
# subcommands:
#   worktree-add    --clone DIR --pr N --mode full|review-only --head-ref REF
#   push            --worktree DIR --dst-ref REF [--remote origin]
#   companion-push  --worktree DIR --branch REF [--remote origin]
#   worktree-remove --clone DIR --worktree DIR
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need jq; ra_need git
ra_reject_forbidden "$@"   # reject dangerous tokens in ALL incoming args

CMD="${1:-}"; shift || true
CLONE=""; WT=""; PR=""; MODE=""; HEADREF=""; DST=""; BRANCH=""; REMOTE="origin"
while [ $# -gt 0 ]; do case "$1" in
  --clone) CLONE="$2"; shift 2 ;;
  --worktree) WT="$2"; shift 2 ;;
  --pr) PR="$2"; shift 2 ;;
  --mode) MODE="$2"; shift 2 ;;
  --head-ref) HEADREF="$2"; shift 2 ;;
  --dst-ref) DST="$2"; shift 2 ;;
  --branch) BRANCH="$2"; shift 2 ;;
  --remote) REMOTE="$2"; shift 2 ;;
  *) shift ;;
esac; done

case "$CMD" in
  worktree-add)
    [ -d "$CLONE/.git" ] || [ -f "$CLONE/.git" ] || ra_die "worktree-add: --clone must be a git repo"
    [ -n "$PR" ] || ra_die "worktree-add: --pr required"
    slug="reviewer-agent/pr${PR}-$(ra_epoch)"
    WT="$CLONE/.git/reviewer-agent-worktrees/pr${PR}-$(ra_epoch)"
    mkdir -p "$(dirname "$WT")"
    if [ "$MODE" = "review-only" ]; then
      # fork / untrusted: detached, read-only intent (never pushed)
      git -C "$CLONE" fetch -q "$REMOTE" "refs/pull/$PR/head" || ra_die "fetch pull/$PR/head failed"
      git -C "$CLONE" worktree add -q --detach "$WT" FETCH_HEAD || ra_die "worktree add (detached) failed"
      sha="$(git -C "$WT" rev-parse HEAD)"
      jq -nc --arg p "$WT" --arg s "$sha" '{action:"worktree-added", path:$p, mode:"review-only", head_sha:$s, branch:null}'
    else
      [ -n "$HEADREF" ] || ra_die "worktree-add full: --head-ref required"
      ra_assert_ref "$HEADREF"
      git -C "$CLONE" fetch -q "$REMOTE" "+refs/heads/$HEADREF:refs/remotes/$REMOTE/$HEADREF" \
        || ra_die "fetch $HEADREF failed (head branch missing?)"
      git -C "$CLONE" worktree add -q -b "$slug" "$WT" "$REMOTE/$HEADREF" || ra_die "worktree add failed"
      sha="$(git -C "$WT" rev-parse HEAD)"
      jq -nc --arg p "$WT" --arg s "$sha" --arg b "$slug" --arg h "$HEADREF" \
        '{action:"worktree-added", path:$p, mode:"full", head_sha:$s, local_branch:$b, push_ref:$h}'
    fi
    ;;

  push)
    [ -d "$WT" ] || ra_die "push: --worktree must exist"
    [ -n "$DST" ] || ra_die "push: --dst-ref required"
    ra_assert_ref "$DST"
    # fast-forward only, hooks enabled (NO --force, NO --no-verify)
    git -C "$WT" push "$REMOTE" "HEAD:refs/heads/$DST" >&2 || ra_die "push rejected (non-ff or no permission)"
    sha="$(git -C "$WT" rev-parse HEAD)"
    jq -nc --arg r "$DST" --arg s "$sha" '{action:"pushed", dst_ref:$r, head_sha:$s}'
    ;;

  companion-push)
    [ -d "$WT" ] || ra_die "companion-push: --worktree must exist"
    [ -n "$BRANCH" ] || ra_die "companion-push: --branch required"
    ra_assert_ref "$BRANCH"
    git -C "$WT" push "$REMOTE" "HEAD:refs/heads/$BRANCH" >&2 || ra_die "companion-push failed"
    sha="$(git -C "$WT" rev-parse HEAD)"
    jq -nc --arg b "$BRANCH" --arg s "$sha" '{action:"companion-pushed", branch:$b, head_sha:$s}'
    ;;

  worktree-remove)
    [ -n "$WT" ] || ra_die "worktree-remove: --worktree required"
    [ -d "$CLONE/.git" ] || [ -f "$CLONE/.git" ] || ra_die "worktree-remove: --clone must be a git repo"
    # --force here removes the agent's OWN throwaway worktree even if dirty
    # (validation artifacts) — not a push/history operation. Safe by construction.
    git -C "$CLONE" worktree remove --force "$WT" >&2 2>/dev/null || true
    jq -nc --arg p "$WT" '{action:"worktree-removed", path:$p}'
    ;;

  *) ra_die "unknown subcommand: '$CMD' (worktree-add|push|companion-push|worktree-remove)" ;;
esac
