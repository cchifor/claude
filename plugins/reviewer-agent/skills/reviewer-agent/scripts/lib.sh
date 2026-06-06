#!/usr/bin/env bash
# reviewer-agent — shared library. Sourced by every scripts/*.sh.
# No side effects on source beyond defining functions + constants.

RA_VERSION="reviewer-agent/0.1.0"
RA_MARKER_BEGIN="<!-- reviewer-agent:state"
RA_MARKER_END="reviewer-agent:state -->"

# Lifecycle labels (mutually-exclusive primary states + sticky overlays).
RA_LABEL_PROCESSING="reviewer-agent:processing"
RA_LABEL_FIXED="reviewer-agent:fixed"
RA_LABEL_MERGED="reviewer-agent:merged"
RA_LABEL_REVIEW_ONLY="reviewer-agent:review-only"
RA_LABEL_NEEDS_HUMAN="reviewer-agent:needs-human"
RA_LABEL_PAUSED="reviewer-agent:paused"

# ── logging (stderr; stdout is reserved for machine-readable JSON) ──
ra_log()  { printf '[reviewer-agent] %s\n' "$*" >&2; }
ra_warn() { printf '[reviewer-agent][warn] %s\n' "$*" >&2; }
ra_die()  { printf '[reviewer-agent][error] %s\n' "$*" >&2; exit 1; }

# Normalize a GitHub target into "owner/repo" or bare "owner".
# Accepts: https://github.com/owner[/repo[/pulls|/pull/N|...]], git@github.com:owner/repo.git,
# github.com/owner/repo, owner/repo, owner.
ra_normalize_slug() {
  local s="$1" owner rest repo
  s="${s#https://github.com/}"; s="${s#http://github.com/}"
  s="${s#git@github.com:}";     s="${s#github.com/}"
  s="${s%.git}"; s="${s%/}"
  owner="${s%%/*}"; rest="${s#"$owner"}"; rest="${rest#/}"; repo="${rest%%/*}"
  if [ -n "$repo" ]; then printf '%s/%s' "$owner" "$repo"; else printf '%s' "$owner"; fi
}

# ── tool detection ──
ra_have() { command -v "$1" >/dev/null 2>&1; }
ra_need() { ra_have "$1" || ra_die "required tool not found on PATH: $1"; }

# Resolve an absolute path for a tool (handles non-login-shell PATH gaps).
ra_path() { command -v "$1" 2>/dev/null || true; }

# Worker identity = host/login. Stable per machine+account; used for locks.
ra_worker_id() {
  local host login
  host="$(hostname 2>/dev/null || echo unknown-host)"
  login="$(gh api user --jq .login 2>/dev/null || echo "$(id -un 2>/dev/null || echo user)")"
  printf '%s/%s' "$host" "$login"
}

# ISO-8601 UTC timestamp. Pure-shell; no Date.now reliance in callers.
ra_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ra_epoch() { date -u +%s; }

# Scratch dir for a (repo,pr). Never inside any repo worktree.
ra_scratch_dir() {
  local repo="$1" pr="$2" base
  base="${XDG_RUNTIME_DIR:-/tmp}/reviewer-agent/$(printf '%s' "$repo" | tr '/:' '__')"
  mkdir -p "$base/$pr"
  printf '%s/%s' "$base" "$pr"
}

# ── safety: reject dangerous tokens anywhere in an argument list ──
# Used by the mutating wrappers as defence-in-depth (the allowlist is NOT a
# boundary — a trailing --force still matches Bash(...:*) globs).
RA_FORBIDDEN_FLAGS='--force -f --force-with-lease --no-verify --no-gpg-sign --amend --admin --yolo --dangerously-bypass-approvals-and-sandbox'
ra_reject_forbidden() {
  local a f
  for a in "$@"; do
    for f in $RA_FORBIDDEN_FLAGS; do
      [ "$a" = "$f" ] && ra_die "refusing: forbidden flag '$f' in command"
    done
  done
}

# A safe branch/ref name: no flags, no whitespace, no '..', no leading '-'.
ra_assert_ref() {
  local ref="$1"
  case "$ref" in
    -*|*..*|*' '*|*'~'*|*'^'*|*':'*|'') ra_die "unsafe ref: '$ref'" ;;
  esac
}

# jq presence is assumed by most scripts (it's a hard dep for JSON state).
ra_need_jq() { ra_need jq; }

# Read a key from a resolved-config JSON file with a default.
# usage: ra_cfg <config_file> <jq-path> <default>
# Uses -rc so scalars come out raw ("squash") and arrays/objects come out as
# COMPACT JSON on one line (["ci","smoke"]) — safe to feed back into --argjson.
ra_cfg() {
  local file="$1" path="$2" def="${3:-}" v
  [ -f "$file" ] || { printf '%s' "$def"; return; }
  v="$(jq -rc "$path // empty" "$file" 2>/dev/null)"
  printf '%s' "${v:-$def}"
}
