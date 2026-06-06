#!/usr/bin/env bash
# detect-validation.sh — resolve HOW to validate a repo checkout. Prints a
# strategy JSON on stdout; validate.sh executes it (always in an isolated
# compose project). Detection only — runs nothing that mutates state.
#
# usage: detect-validation.sh --repo-dir DIR --config-file CONFIG.json
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
ra_need_jq

DIR=""; CFG=""
while [ $# -gt 0 ]; do case "$1" in
  --repo-dir) DIR="$2"; shift 2 ;;
  --config-file) CFG="$2"; shift 2 ;;
  *) shift ;;
esac; done
[ -n "$DIR" ] && [ -d "$DIR" ] || ra_die "detect-validation: --repo-dir must be an existing directory"

override="$(ra_cfg "$CFG" '.validation_cmd' '')"
level="$(ra_cfg "$CFG" '.validation_level' 'slim')"

emit() { jq -n "$@"; exit 0; }

has() { [ -e "$DIR/$1" ]; }
grep_q() { grep -qs "$1" "$DIR/$2" 2>/dev/null; }

# 1. explicit override (from trusted base-branch config / invocation)
if [ -n "$override" ]; then
  emit --arg cmd "$override" --arg lvl "$level" \
    '{source:"override", level:$lvl, docker:false, command:$cmd, needs_isolation:true}'
fi

# 1b. forced unit rung — `validation_level: unit` skips all docker/Makefile rungs
if [ "$level" = unit ]; then
  { has 'mise.toml' && grep_q 'tasks.test' mise.toml; } && emit '{source:"mise-unit", level:"unit", docker:false, partial:true, command:"mise run test"}'
  has 'pyproject.toml' && emit '{source:"unit", level:"unit", docker:false, partial:true, command:"uv run pytest -m \"not integration and not docker and not e2e and not slow\" --tb=short -q || pytest -q"}'
  { has 'package.json' && grep_q '"test"' package.json; } && emit '{source:"unit", level:"unit", docker:false, partial:true, command:"npm test --silent"}'
  has 'Cargo.toml' && emit '{source:"unit", level:"unit", docker:false, partial:true, command:"cargo test"}'
  has 'go.mod' && emit '{source:"unit", level:"unit", docker:false, partial:true, command:"go test ./..."}'
  emit '{source:"none", level:"unit", docker:false, partial:true, command:""}'
fi

runner=""
grep_q 'e2e-runner' 'docker-compose.test.yml' && runner="e2e-runner"

# 2. platform staged path: scripts/up.sh + test overlay + e2e-runner service
if has 'scripts/up.sh' && has 'docker-compose.test.yml' && [ -n "$runner" ]; then
  if [ "$level" = full ]; then
    emit --arg lvl full \
      '{source:"mise-staged-full", level:$lvl, docker:true, use_up_sh:true,
        compose_files:["docker-compose.yml","docker-compose.test.yml"],
        up_profiles:"hatchet,workers,observability", wait_timeout:240,
        runner_service:"e2e-runner", runner_cmd:["test","--project=journey"], needs_isolation:true}'
  else
    emit --arg lvl slim \
      '{source:"mise-staged-slim", level:$lvl, docker:true, use_up_sh:true,
        compose_files:["docker-compose.yml","docker-compose.test.yml"],
        up_profiles:"", wait_timeout:180,
        runner_service:"e2e-runner", runner_cmd:["test","--project=smoke"], needs_isolation:true}'
  fi
fi

# 3. Makefile with a recognised test target
if has 'Makefile' || has 'makefile'; then
  for t in test ci check; do
    if grep_q "^$t:" Makefile || grep_q "^$t:" makefile; then
      emit --arg cmd "make $t" --arg lvl "$level" \
        '{source:"makefile", level:$lvl, docker:false, command:$cmd, needs_isolation:false}'
    fi
  done
fi

# 4. generic compose with an e2e-runner service (no up.sh)
if [ -n "$runner" ] && has 'docker-compose.yml'; then
  emit --arg lvl "$level" \
    '{source:"compose-test", level:$lvl, docker:true, use_up_sh:false,
      compose_files:["docker-compose.yml","docker-compose.test.yml"], wait_timeout:180,
      runner_service:"e2e-runner", runner_cmd:["test"], needs_isolation:true}'
fi

# 5. unit fallback by language — validation=partial (no full-stack signal)
if has 'pyproject.toml'; then
  emit '{source:"unit", level:"unit", docker:false, partial:true,
        command:"uv run pytest -m \"not integration and not docker and not e2e and not slow\" --tb=short -q || pytest -q"}'
fi
if has 'package.json' && grep_q '"test"' package.json; then
  emit '{source:"unit", level:"unit", docker:false, partial:true, command:"npm test --silent"}'
fi
has 'Cargo.toml' && emit '{source:"unit", level:"unit", docker:false, partial:true, command:"cargo test"}'
has 'go.mod' && emit '{source:"unit", level:"unit", docker:false, partial:true, command:"go test ./..."}'

# 6. nothing detected
emit '{source:"none", level:"none", docker:false, partial:true, command:""}'
