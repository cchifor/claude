#!/usr/bin/env bash
# validate.sh — execute a validation strategy (from detect-validation.sh) in an
# ISOLATED compose project so it can never touch the developer's running stack.
# The verdict is the TEST-RUNNER exit code (not the lenient up.sh bring-up exit).
# Tears down ONLY its own project on exit. Prints a result JSON on stdout.
#
# Heavy stacks can take minutes — the caller SHOULD run this with
# run_in_background. An outer `timeout` self-bounds the run.
#
# usage: validate.sh --repo-dir DIR --strategy-file STRAT.json [--config-file C] [--pr N]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need jq
ra_reject_forbidden "$@"

DIR=""; STRAT=""; CFG=""; PR="x"; MODE=""   # default empty => fail closed; require --mode full to execute
while [ $# -gt 0 ]; do case "$1" in
  --repo-dir) DIR="$2"; shift 2 ;;
  --strategy-file) STRAT="$2"; shift 2 ;;
  --config-file) CFG="$2"; shift 2 ;;
  --pr) PR="$2"; shift 2 ;;
  --mode) MODE="$2"; shift 2 ;;
  *) shift ;;
esac; done
[ -d "$DIR" ] || ra_die "validate: --repo-dir must exist"
[ -f "$STRAT" ] || ra_die "validate: --strategy-file required"

# TRUST GATE: never execute review-only / untrusted (fork) PR code locally.
[ "$MODE" = full ] || { jq -nc --arg m "$MODE" \
  '{result:"skipped", reason:"not-full-mode", mode:$m, note:"review-only/untrusted checkouts are never executed locally"}'; exit 0; }

S() { jq -r "$1 // empty" "$STRAT"; }
source_kind="$(S '.source')"
docker="$(S '.docker')"
partial="$(jq -r '.partial // false' "$STRAT")"
OUTER_TIMEOUT="$(ra_cfg "$CFG" '.validation_timeout' '1800')"; [ -n "$OUTER_TIMEOUT" ] || OUTER_TIMEOUT=1800
log="$(ra_scratch_dir "${REPO:-repo}" "$PR")/validate-${source_kind}.log"
: >"$log"

emit() { jq -nc "$@"; exit 0; }
tail_evidence() { tail -n 60 "$log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | jq -Rs .; }

if [ "$source_kind" = "none" ]; then
  emit --arg s none '{result:"partial", partial:true, source:$s, evidence:"no validation strategy detected"}'
fi

# ── non-docker: run the literal command in the checkout ──
if [ "$docker" != "true" ]; then
  cmd="$(S '.command')"
  [ -n "$cmd" ] || emit --arg s "$source_kind" '{result:"partial", partial:true, source:$s, evidence:"empty command"}'
  ra_log "validate ($source_kind): $cmd"
  ( cd "$DIR" && timeout "$OUTER_TIMEOUT" bash -lc "$cmd" ) >>"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    emit --arg s "$source_kind" --argjson p "$partial" --argjson ev "$(tail_evidence)" \
      '{result: (if $p then "partial" else "green" end), partial:$p, source:$s, exit:0, evidence:$ev}'
  else
    emit --arg s "$source_kind" --argjson ev "$(tail_evidence)" \
      '{result:"fail", partial:false, source:$s, exit:'"$rc"', evidence:$ev}'
  fi
fi

# ── docker: isolated compose project ──
ra_need docker
docker compose version >/dev/null 2>&1 || ra_die "validate: docker compose unavailable"
[ "$(ra_cfg "$CFG" '.repo' '')" ] && REPO="$(ra_cfg "$CFG" '.repo' '')" || REPO="repo"

PROJECT="ra-pr${PR}-$(ra_epoch)"
mapfile -t CF < <(jq -r '.compose_files[]? // empty' "$STRAT")
FILES=""; for f in "${CF[@]}"; do FILES="$FILES -f $f"; done
[ -n "$FILES" ] || FILES="-f docker-compose.yml"
COMPOSE="-p $PROJECT $FILES"
up_profiles="$(S '.up_profiles')"
wait_to="$(jq -r '.wait_timeout // 180' "$STRAT")"
runner="$(S '.runner_service')"
mapfile -t RCMD < <(jq -r '.runner_cmd[]? // empty' "$STRAT")
use_up_sh="$(jq -r '.use_up_sh // false' "$STRAT")"

cd "$DIR"
# teardown ONLY this project's resources — never the developer's default project
# shellcheck disable=SC2086
trap 'docker compose '"$COMPOSE"' down -v --remove-orphans >>"'"$log"'" 2>&1 || true' EXIT
export COMPOSE_PROFILES="$up_profiles"

ra_log "validate ($source_kind): project=$PROJECT files=$FILES profiles='${up_profiles}'"
# Run IN-PROCESS (not via `bash -c "$(declare -f …)"`, which would lose $COMPOSE/
# $RCMD/cwd and collapse isolation to the default project). Each long step is
# individually bounded by `timeout`. The verdict is the TEST RUNNER's exit.
rc=0
{
  if [ -n "$runner" ]; then
    # shellcheck disable=SC2086
    timeout "$OUTER_TIMEOUT" docker compose $COMPOSE build "$runner" || rc=90
  fi
  if [ "$rc" -eq 0 ]; then
    if [ "$use_up_sh" = true ] && [ -f scripts/up.sh ]; then
      # inject -p + -f via UP_COMPOSE_FILES so up.sh's `docker compose $FILES` is isolated
      UP_COMPOSE_FILES="$COMPOSE" UP_PROFILES="$up_profiles" UP_WAIT_TIMEOUT="$wait_to" \
        timeout "$OUTER_TIMEOUT" bash scripts/up.sh || rc=91   # up.sh: nonzero only if the core tier failed
    else
      # shellcheck disable=SC2086
      timeout "$OUTER_TIMEOUT" docker compose $COMPOSE up -d --wait --wait-timeout "$wait_to" || rc=91
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -n "$runner" ]; then
    # shellcheck disable=SC2086
    timeout "$OUTER_TIMEOUT" docker compose $COMPOSE run --rm "$runner" "${RCMD[@]}"; rc=$?
  fi
} >>"$log" 2>&1

# record any unhealthy services for the evidence trail (informational)
unhealthy="$(docker compose $COMPOSE ps --format json 2>/dev/null | jq -rs '[.[]?|select(.Health=="unhealthy")|.Service] | join(",")' 2>/dev/null || echo "")"

if [ "$rc" -eq 0 ]; then
  emit --arg s "$source_kind" --arg p "$PROJECT" --arg u "$unhealthy" --argjson ev "$(tail_evidence)" \
    '{result:"green", partial:false, source:$s, project:$p, unhealthy:$u, evidence:$ev}'
elif [ "$rc" -eq 124 ]; then
  emit --arg s "$source_kind" --arg p "$PROJECT" --argjson ev "$(tail_evidence)" \
    '{result:"fail", partial:false, source:$s, project:$p, reason:"timeout", evidence:$ev}'
else
  emit --arg s "$source_kind" --arg p "$PROJECT" --arg u "$unhealthy" --argjson ev "$(tail_evidence)" \
    '{result:"fail", partial:false, source:$s, project:$p, exit:'"$rc"', unhealthy:$u, evidence:$ev}'
fi
