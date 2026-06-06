#!/usr/bin/env bash
#
# cleanup.sh — reclaim local dev-box resources safely.
#
# Portable: no hardcoded paths, usernames, repo names, or service names.
# Detects available tools; absent ones are skipped (never an error).
#
# Posture:
#   SAFE tier      -> applied automatically (regenerable: docker build cache,
#                     dangling images, exited containers, package caches, old temp)
#   AGGRESSIVE tier -> off unless its flag is given, and prompts before acting
#                     (unused images, volumes, stale branches/worktrees, build
#                      artifacts, stuck jobs)
#
# Guards (never bypassable):
#   * never `docker system prune -a --volumes`
#   * never touch containers/images/volumes of a RUNNING compose project
#   * never delete the current branch, a worktree-checked-out branch, or a
#     branch with commits not present on any remote
#   * never kill PID 1, kernel threads, sshd, the docker daemon, or our own tree
#
# Run `cleanup.sh --help` for usage.

set -euo pipefail

# ----------------------------------------------------------------------------
# Config (all overridable via env or flags) — no machine-specific defaults.
# ----------------------------------------------------------------------------
ROOT="${CLEANUP_ROOT:-$(pwd)}"        # where to discover git repos
TMP_DAYS="${CLEANUP_TMP_DAYS:-7}"     # age threshold for temp leftovers
SCAN_DEPTH="${CLEANUP_SCAN_DEPTH:-4}" # max depth when discovering .git dirs

DRY_RUN=0
ASSUME_YES=0
DO_IMAGES=0
DO_VOLUMES=0
DO_BRANCHES=0
DO_WORKTREES=0
DO_JOBS=0
KILL_JOBS=0
REAP_RESTART=0
ARTIFACT_PATHS=()
REPO_PATHS=()

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'; C_RST=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_RST=""
fi

section() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RST"; }
info()    { printf '%s\n' "$1"; }
note()    { printf '%s· %s%s\n' "$C_DIM" "$1" "$C_RST"; }
warn()    { printf '%s! %s%s\n' "$C_YELLOW" "$1" "$C_RST"; }
danger()  { printf '%s!! %s%s\n' "$C_RED" "$1" "$C_RST"; }
ok()      { printf '%s✓ %s%s\n' "$C_GREEN" "$1" "$C_RST"; }
skip()    { note "skip: $1"; }

have() { command -v "$1" >/dev/null 2>&1; }
docker_ok() { have docker && docker info >/dev/null 2>&1; }

# Sum docker's "Reclaimable" column to a single GB figure (handles TB/GB/MB/kB/B).
docker_reclaimable_gb() {
  docker system df --format '{{.Reclaimable}}' 2>/dev/null | awk '
    function toGB(s,   n,u){ n=s+0; u=s; sub(/^[0-9.]+/,"",u)
      if(u ~ /TB/) return n*1024; if(u ~ /GB/) return n; if(u ~ /MB/) return n/1024
      if(u ~ /kB|KB/) return n/1048576; if(u ~ /B/) return n/1073741824; return 0 }
    { line=$0; gsub(/\(.*/,"",line); gsub(/[ \t]/,"",line); if(line!="") s+=toGB(line) }
    END { printf "%.2f", s+0 }'
}

# Container id for a host PID via its cgroup (docker/containerd), else empty.
pid_container_id() {
  grep -ao 'docker[-/][0-9a-f]\{12,64\}' "/proc/$1/cgroup" 2>/dev/null \
    | head -1 | grep -o '[0-9a-f]\{12,64\}'
}

# Run a command, honoring --dry-run. Prints what it would/will do.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  printf '%s$%s %s\n' "$C_DIM" "$C_RST" "$*"
  "$@"
}

# Confirm before an aggressive action (auto-yes with --yes or in dry-run).
confirm() {
  local prompt="$1"
  if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    warn "non-interactive and no --yes; skipping: $prompt"
    return 1
  fi
  printf '%s? %s [y/N] %s' "$C_YELLOW" "$prompt" "$C_RST"
  local reply=""
  read -r reply || true
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) note "skipped"; return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
cleanup.sh — reclaim local dev-box resources safely.

USAGE
  cleanup.sh [options]

  With no tier flags it prints an analysis report and applies only the SAFE
  tier (regenerable caches/build-cache/dangling images/exited containers/old
  temp). Aggressive actions require their flag and prompt before running.

OPTIONS
  --dry-run            Report only; print every command without executing.
  --report             Alias for --dry-run (analysis only).
  -y, --yes            Skip confirmation prompts for aggressive actions.

  --images             Aggressive: remove unused (not just dangling) images.
  --volumes            Aggressive: remove dangling volumes (DATA LOSS risk;
                       volumes attached to running containers are kept).
  --branches           Aggressive: delete local branches whose upstream is gone
                       AND fully merged AND fully pushed (uses `git branch -d`).
  --worktrees          Aggressive: prune administrative stale-worktree records
                       and list removable worktrees.
  --artifacts PATH     Aggressive: remove build artifacts (node_modules, .venv,
                       target, dist, __pycache__, .pytest_cache) under PATH.
                       Repeatable.
  --jobs               Diagnose zombie/orphaned processes: attribute each to its
                       parent + container, report init status, prescribe the fix.
  --kill               With --jobs: SIGCHLD-nudge reaping parents (best effort;
                       only works if the parent has a handler). Prompts.
  --restart-parents    With --jobs: restart container parents of zombies to clear
                       them definitively (brief service downtime). Prompts each.

  --root PATH          Root to discover git repos under (default: cwd).
  --repo PATH          Operate on this specific repo (repeatable; overrides
                       discovery for branch/worktree actions).
  --days N             Temp-file age threshold in days (default: 7).
  -h, --help           This help.

ENV
  CLEANUP_ROOT, CLEANUP_TMP_DAYS, CLEANUP_SCAN_DEPTH

EXAMPLES
  cleanup.sh                       # report + safe auto-clean
  cleanup.sh --dry-run             # see everything, change nothing
  cleanup.sh --images --volumes -y # also reclaim unused images + dangling vols
  cleanup.sh --branches --repo .   # prune merged/gone branches in this repo
  cleanup.sh --artifacts ./build   # nuke build artifacts under ./build
  cleanup.sh --jobs                # list stuck/zombie processes
EOF
}

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|--report) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --images) DO_IMAGES=1 ;;
    --volumes) DO_VOLUMES=1 ;;
    --branches) DO_BRANCHES=1 ;;
    --worktrees) DO_WORKTREES=1 ;;
    --jobs) DO_JOBS=1 ;;
    --kill) KILL_JOBS=1 ;;
    --restart-parents) REAP_RESTART=1 ;;
    --artifacts) shift; [ $# -gt 0 ] || { danger "--artifacts needs a PATH"; exit 2; }; ARTIFACT_PATHS+=("$1") ;;
    --root) shift; [ $# -gt 0 ] || { danger "--root needs a PATH"; exit 2; }; ROOT="$1" ;;
    --repo) shift; [ $# -gt 0 ] || { danger "--repo needs a PATH"; exit 2; }; REPO_PATHS+=("$1") ;;
    --days) shift; [ $# -gt 0 ] || { danger "--days needs N"; exit 2; }; TMP_DAYS="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) danger "unknown option: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------

# Resolve a path inside a repo to its MAIN worktree root, so linked worktrees
# (which share one object store) collapse to a single logical repo.
main_worktree() {
  local common
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$1/$common" ;; esac
  (cd "$common/.." 2>/dev/null && pwd)
}

# Echo discovered git repo roots (one per line, deduped), honoring --repo override.
discover_repos() {
  { if [ "${#REPO_PATHS[@]}" -gt 0 ]; then
      local p
      for p in "${REPO_PATHS[@]}"; do
        if git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
          main_worktree "$p"
        else
          warn "not a git repo: $p" >&2
        fi
      done
    else
      [ -d "$ROOT" ] || return 0
      # Find .git entries up to SCAN_DEPTH; map each to its main worktree root.
      find "$ROOT" -maxdepth "$SCAN_DEPTH" -name .git \( -type d -o -type f \) -prune 2>/dev/null \
        | while IFS= read -r g; do main_worktree "$(dirname "$g")"; done
    fi
  } | awk 'NF && !seen[$0]++'
}

# Default branch for a repo (origin/HEAD, fallback main/master/current).
default_branch() {
  local repo="$1" d
  d=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@') || true
  if [ -n "$d" ]; then printf '%s\n' "$d"; return; fi
  for c in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$c"; then printf '%s\n' "$c"; return; fi
  done
  git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main
}

# Names of branches checked out in any worktree of a repo.
worktree_branches() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | sed -n 's@^branch refs/heads/@@p'
}

# ----------------------------------------------------------------------------
# Analysis report
# ----------------------------------------------------------------------------
report() {
  section "System overview"
  if have df; then df -h "$ROOT" 2>/dev/null | sed -n '1p;2p' || true; fi

  # Headline: how full + the single biggest reclaim lever (docker) up front.
  local usepct avail dre
  usepct=$(df -hP "$ROOT" 2>/dev/null | awk 'NR==2{print $5}')
  avail=$(df -hP "$ROOT" 2>/dev/null | awk 'NR==2{print $4}')
  printf '  disk: %s used, %s free at %s\n' "${usepct:-?}" "${avail:-?}" "$ROOT"
  if docker_ok; then
    dre=$(docker_reclaimable_gb)
    printf '  docker reclaimable (safe + --images + --volumes): ~%s GB\n' "${dre:-0}"
    note "package/tool caches add more below; safe tier reclaims build cache + dangling + caches."
  fi

  if docker_ok; then
    section "Docker"
    docker system df 2>/dev/null || true
    local running
    running=$(docker compose ls --format '{{.Name}}' 2>/dev/null | tr '\n' ' ' || true)
    [ -n "${running// }" ] && warn "running compose projects (protected): ${running}"
  else
    note "docker: not available — docker categories will be skipped"
  fi

  section "Package / tool caches"
  local d
  for pair in \
    "npm:$(have npm && npm config get cache 2>/dev/null || echo '')" \
    "uv:$( (have uv && uv cache dir 2>/dev/null) || echo "${UV_CACHE_DIR:-}")" \
    "pip:$(have pip && pip cache dir 2>/dev/null || echo '')" \
    "go:$(have go && go env GOCACHE 2>/dev/null || echo '')" ; do
    name="${pair%%:*}"; d="${pair#*:}"
    if [ -n "$d" ] && [ -d "$d" ]; then printf '  %-6s %s  %s\n' "$name" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$d"; fi
  done
  [ -n "${XDG_CACHE_HOME:-$HOME/.cache}" ] && [ -d "${XDG_CACHE_HOME:-$HOME/.cache}" ] \
    && printf '  %-6s %s  %s\n' "cache" "$(du -sh "${XDG_CACHE_HOME:-$HOME/.cache}" 2>/dev/null | cut -f1)" "${XDG_CACHE_HOME:-$HOME/.cache}"

  if have git; then
    section "Git repos (under $ROOT)"
    local repo def gone_n
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      def=$(default_branch "$repo")
      gone_n=$(git -C "$repo" branch -vv 2>/dev/null | grep -c ': gone\]' || true)
      printf '  %s  (default: %s, gone-upstream: %s)\n' "$repo" "$def" "$gone_n"
    done < <(discover_repos)
  fi

  section "Stuck / zombie processes"
  local z
  # shellcheck disable=SC2009  # need process STAT field; pgrep can't filter zombies
  z=$(ps -eo stat= 2>/dev/null | grep -c '^Z' || true)
  printf '  zombies: %s\n' "$z"
  if [ "${z:-0}" -gt 0 ]; then
    note "top reaping parents (pid × count):"
    ps -eo ppid=,stat= 2>/dev/null | awk '$2 ~ /Z/ {print $1}' \
      | sort | uniq -c | sort -rn | head -5 \
      | while read -r c p; do
          printf '    %s× pid %s (%s)\n' "$c" "$p" "$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')"
        done
    note "run with --jobs for root-cause attribution + fix; many zombies under one container ⇒ missing 'init: true'."
  fi
}

# ----------------------------------------------------------------------------
# SAFE tier
# ----------------------------------------------------------------------------
safe_docker() {
  docker_ok || { note "docker unavailable — skipping docker safe tier"; return 0; }
  section "Docker — safe reclaim"
  run docker builder prune -f
  run docker image prune -f          # dangling only; never -a here
  # List exited containers before removing (prune skips running ones inherently).
  local exited
  exited=$(docker ps -a --filter status=exited --filter status=created -q 2>/dev/null | wc -l | tr -d ' ')
  if [ "${exited:-0}" -gt 0 ]; then
    note "removing $exited exited/created container(s) (running containers are untouched)"
    run docker container prune -f
  fi
}

safe_caches() {
  section "Package / tool caches — safe reclaim"
  if have npm; then run npm cache verify >/dev/null || true; ok "npm cache verified"; else skip "npm"; fi
  if have uv;  then run uv cache prune || true; else skip "uv"; fi
  if have pip; then run pip cache purge || true; else skip "pip"; fi
  if have pnpm; then run pnpm store prune || true; else skip "pnpm"; fi
  if have go;  then note "go build cache left intact (use 'go clean -cache' manually)"; fi
}

safe_temp() {
  section "Temp leftovers (> ${TMP_DAYS}d, owned by you)"
  local me t
  me=$(id -u)
  for t in /tmp /var/tmp "${TMPDIR:-}"; do
    { [ -n "$t" ] && [ -d "$t" ]; } || continue
    # Only our own files, older than threshold; never recurse into mountpoints we don't own.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      run rm -f -- "$f"
    done < <(find "$t" -maxdepth 1 -type f -uid "$me" -mtime "+${TMP_DAYS}" 2>/dev/null)
  done
  ok "temp sweep done"
}

# ----------------------------------------------------------------------------
# AGGRESSIVE tier
# ----------------------------------------------------------------------------
aggr_images() {
  docker_ok || { skip "docker (images)"; return 0; }
  section "Docker — unused images (aggressive)"
  warn "this removes images not used by any container (re-pull/rebuild cost)."
  if confirm "Remove all unused images (docker image prune -a)?"; then
    run docker image prune -a -f
  fi
}

aggr_volumes() {
  docker_ok || { skip "docker (volumes)"; return 0; }
  section "Docker — dangling volumes (aggressive, DATA LOSS risk)"
  danger "volumes can hold databases. Volumes attached to running containers are kept by docker."
  local dangling
  dangling=$(docker volume ls -qf dangling=true 2>/dev/null | wc -l | tr -d ' ')
  note "$dangling dangling volume(s) candidate"
  if [ "${dangling:-0}" -gt 0 ] && confirm "Remove $dangling dangling volume(s)?"; then
    run docker volume prune -f
  fi
}

aggr_branches() {
  have git || { skip "git (branches)"; return 0; }
  section "Git — stale branches (aggressive)"
  local repo def cur wts b unpushed
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    def=$(default_branch "$repo")
    cur=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    wts=$(worktree_branches "$repo")
    info "${C_BOLD}$repo${C_RST} (default: $def)"
    # Candidate = upstream gone. Then enforce: not current, not in a worktree,
    # fully merged into default, and zero commits absent from all remotes.
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      [ "$b" = "$def" ] && continue
      if [ "$b" = "$cur" ]; then note "keep $b (current branch)"; continue; fi
      if printf '%s\n' "$wts" | grep -qxF "$b"; then note "keep $b (checked out in a worktree)"; continue; fi
      unpushed=$(git -C "$repo" rev-list --count "$b" --not --remotes 2>/dev/null || echo 1)
      if [ "${unpushed:-1}" != "0" ]; then warn "keep $b ($unpushed unpushed commit(s))"; continue; fi
      if ! git -C "$repo" branch --merged "$def" 2>/dev/null | sed 's/^[* +]*//' | grep -qxF "$b"; then
        warn "keep $b (not fully merged into $def)"; continue
      fi
      if confirm "Delete merged+gone branch '$b' in $(basename "$repo")?"; then
        run git -C "$repo" branch -d "$b"   # -d refuses unmerged as a backstop
      fi
    done < <(git -C "$repo" branch -vv 2>/dev/null | grep ': gone\]' | sed 's/^[* +]*//' | awk '{print $1}')
  done < <(discover_repos)
}

aggr_worktrees() {
  have git || { skip "git (worktrees)"; return 0; }
  section "Git — worktrees (aggressive)"
  local repo
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    info "${C_BOLD}$repo${C_RST}"
    run git -C "$repo" worktree prune -v   # removes only already-deleted worktree records
    # List live worktrees so the user can remove intentionally; we never auto-remove a live checkout.
    git -C "$repo" worktree list 2>/dev/null | sed '1d' | while IFS= read -r line; do
      note "live worktree (remove manually if done): $line"
    done
  done < <(discover_repos)
}

aggr_artifacts() {
  section "Build artifacts (aggressive)"
  local p
  for p in "${ARTIFACT_PATHS[@]}"; do
    [ -d "$p" ] || { warn "not a dir: $p"; continue; }
    if confirm "Remove build artifacts under '$p'?"; then
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        run rm -rf -- "$d"
      done < <(find "$p" \( -name node_modules -o -name .venv -o -name target \
                            -o -name dist -o -name __pycache__ -o -name .pytest_cache \) \
                       -type d -prune 2>/dev/null)
    fi
  done
}

# Decide whether a parent PID is one we must never signal/restart blindly.
protected_parent() {
  local pp="$1" pcomm
  [ "$pp" = "1" ] && return 0
  case " $$ $PPID " in *" $pp "*) return 0 ;; esac
  pcomm=$(ps -o comm= -p "$pp" 2>/dev/null | tr -d ' ')
  case "$pcomm" in sshd|dockerd|systemd|containerd|init) return 0 ;; esac
  return 1
}

aggr_jobs() {
  section "Stuck / zombie processes"

  # Group zombies by reaping parent (portable: no associative arrays).
  local zppids total parents
  zppids=$(ps -eo ppid=,stat= 2>/dev/null | awk '$2 ~ /Z/ {print $1}')
  total=$(printf '%s\n' "$zppids" | grep -c '[0-9]' || true)
  if [ "${total:-0}" -eq 0 ]; then ok "no zombie processes"; else
    warn "$total zombie (defunct) process(es) — children that exited but were never reaped"
  fi
  # "count pid" lines, busiest first.
  parents=$(printf '%s\n' "$zppids" | grep '[0-9]' | sort | uniq -c | sort -rn || true)

  # Diagnose each parent: command, container, init status, and the real remedy.
  local cnt pp pcomm cid cname cinit
  while read -r cnt pp; do
    [ -n "${pp:-}" ] || continue
    case " $$ $PPID " in *" $pp "*) continue ;; esac   # skip our own tree
    pcomm=$(ps -o comm= -p "$pp" 2>/dev/null | tr -d ' '); pcomm=${pcomm:-gone}
    printf '\n  %sparent pid=%s (%s) — %s zombie(s)%s\n' "$C_BOLD" "$pp" "$pcomm" "$cnt" "$C_RST"
    cid=$(pid_container_id "$pp")
    if [ -n "$cid" ] && docker_ok; then
      cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's@^/@@')
      cinit=$(docker inspect --format '{{.HostConfig.Init}}' "$cid" 2>/dev/null)
      printf '    container=%s  init=%s\n' "${cname:-?}" "${cinit:-?}"
      if [ "$cinit" != "true" ]; then
        danger "    root cause: app runs as PID 1 with no init/reaper (init=$cinit) — orphaned children never get wait()ed."
        info   "    ${C_BOLD}PERMANENT FIX${C_RST}: add  init: true  to service '${cname:-<svc>}' in docker-compose"
        info   "                   (equiv: 'docker run --init', or bake tini/dumb-init as entrypoint)."
        info   "    CLEAR NOW    : docker restart ${cname:-<container>}   (zombies die with their parent)"
      else
        warn   "    has init=true yet zombies persist — app likely double-forks; fix subprocess reaping in the app."
      fi
    else
      note "    host process (not containerized)."
      info "    FIX: make it reap children — subprocess.run()/proc.wait(), .join() workers, or signal(SIGCHLD, SIG_IGN)."
    fi
  done < <(printf '%s\n' "$parents")

  # Orphaned long-lived dev servers (reparented to init): often forgotten by hand.
  local orphans
  orphans=$(ps -eo pid=,ppid=,etimes=,comm=,args= 2>/dev/null \
    | awk '$3>1800 && $2==1' \
    | grep -Ei 'vite|uvicorn|gunicorn|pytest|webpack|playwright|jest|next|nodemon|hatchet' \
    | grep -vE '[ /]cleanup\.sh' || true)
  if [ -n "$orphans" ]; then
    note "orphaned long-lived dev servers (reparented to init; review and kill by hand if stale):"
    printf '%s\n' "$orphans" | sed 's/^/    /'
  fi

  # --restart-parents: definitive clear by restarting the container parent.
  if [ "$REAP_RESTART" -eq 1 ]; then
    section "Clearing zombies by restarting container parents"
    while read -r cnt pp; do
      [ -n "${pp:-}" ] || continue
      if protected_parent "$pp"; then warn "skip protected parent $pp"; continue; fi
      cid=$(pid_container_id "$pp"); [ -n "$cid" ] || { note "parent $pp not a container — cannot restart; fix app reaping"; continue; }
      docker_ok || continue
      cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's@^/@@')
      if confirm "Restart container '${cname:-$cid}' to clear $cnt zombie(s)? (brief downtime for that service)"; then
        run docker restart "${cname:-$cid}"
      fi
    done < <(printf '%s\n' "$parents")
  fi

  # --kill: cheap SIGCHLD nudge. Honest: only clears zombies if the parent has a
  # SIGCHLD handler it failed to run; app servers that never wait() won't budge.
  if [ "$KILL_JOBS" -eq 1 ]; then
    section "SIGCHLD nudge (best effort)"
    while read -r cnt pp; do
      [ -n "${pp:-}" ] || continue
      if protected_parent "$pp"; then warn "refusing to signal protected parent $pp"; continue; fi
      pcomm=$(ps -o comm= -p "$pp" 2>/dev/null | tr -d ' ')
      if confirm "Send SIGCHLD to parent $pp (${pcomm:-?})? (no-op if it has no handler)"; then
        run kill -CHLD "$pp" || true
      fi
    done < <(printf '%s\n' "$parents")
    note "if zombies remain, the parent isn't reaping — use --restart-parents or add 'init: true'."
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  printf '%scleanup.sh%s  root=%s  %s\n' "$C_BOLD" "$C_RST" "$ROOT" \
    "$( [ "$DRY_RUN" -eq 1 ] && echo "${C_YELLOW}[dry-run]${C_RST}" || echo "${C_GREEN}[safe auto-apply]${C_RST}" )"

  report

  # SAFE tier — auto-applied (unless dry-run, where run() just prints).
  safe_docker
  safe_caches
  safe_temp

  # AGGRESSIVE tier — only when explicitly requested.
  [ "$DO_IMAGES" -eq 1 ]    && aggr_images
  [ "$DO_VOLUMES" -eq 1 ]   && aggr_volumes
  [ "$DO_BRANCHES" -eq 1 ]  && aggr_branches
  [ "$DO_WORKTREES" -eq 1 ] && aggr_worktrees
  [ "${#ARTIFACT_PATHS[@]}" -gt 0 ] && aggr_artifacts
  [ "$DO_JOBS" -eq 1 ]      && aggr_jobs

  section "Done"
  if [ "$DRY_RUN" -eq 1 ]; then
    note "dry-run: nothing was changed. Re-run without --dry-run to apply the safe tier."
  fi
  if docker_ok; then docker system df 2>/dev/null || true; fi
}

main
