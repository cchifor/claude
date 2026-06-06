---
name: cleanup-local-resources
description: Use when a dev machine is low on disk or cluttered and you need to reclaim space — docker images/build-cache/volumes, package caches (npm/uv/pip/pnpm/go), stale git branches and worktrees, temp/build artifacts, and zombie/orphaned processes — safely, without disturbing running services, unpushed commits, or checked-out branches.
---

# Cleanup Local Resources

## Overview

Reclaim disk and clear clutter on a dev box **without breaking active work**.
The bundled `cleanup.sh` always reports first, **auto-applies a safe tier** of
regenerable cleanups, and only performs destructive (aggressive) actions when
you pass their flag and confirm.

**Core principle:** regenerable junk goes automatically; anything that could
destroy state (volumes, branches, processes, worktrees) is opt-in, guarded, and
confirmed. Discovery-based — no machine, repo, or service names are assumed.

## When to use

- Disk is filling up (`No space left`, high `df` usage, slow builds).
- Docker has ballooned (large build cache, many dangling/unused images).
- Many merged feature branches or stale worktrees linger after PRs merge.
- Caches (`~/.npm`, uv, pip) have grown large.
- Zombie/orphaned processes are piling up.

**When NOT to use:** to free space inside CI (use the runner's own pruning), or
to remove something you *know* you still need — pass `--dry-run` first and read
the report.

## Quick reference

> **Run `cleanup.sh --dry-run` first to preview.** The bare `cleanup.sh` is
> **state-changing** — it applies the safe tier (mutates Docker + caches)
> immediately. Only `--dry-run`/`--report` change nothing.

| Invocation | Effect |
|---|---|
| `cleanup.sh` | **(mutates)** Report + apply **safe tier** (build cache, dangling images, exited containers, package caches, old temp). |
| `cleanup.sh --dry-run` | Report only; print every command, change nothing. |
| `cleanup.sh --images` | + remove unused (non-dangling) images. Aggressive, prompts. |
| `cleanup.sh --volumes` | + remove dangling volumes. **Data-loss risk**, prompts. |
| `cleanup.sh --branches [--repo P]` | Delete branches that are gone-upstream **and** merged **and** fully pushed. Without `--repo`, fans out across **every** repo under `--root`; pass `--repo PATH` to scope to one. |
| `cleanup.sh --worktrees` | Prune stale worktree records; list live worktrees. |
| `cleanup.sh --artifacts PATH` | Remove `node_modules/.venv/target/dist/__pycache__/.pytest_cache` under PATH. |
| `cleanup.sh --jobs` | Diagnose zombies: attribute to parent + container, show init status, prescribe fix. |
| `cleanup.sh --jobs --restart-parents` | Clear zombies by restarting their container parents (prompts; brief downtime). |
| `cleanup.sh --jobs --kill` | Best-effort SIGCHLD nudge to reaping parents (prompts). |
| `--root PATH` / `--days N` / `-y` | Discovery root / temp age / skip prompts. |

Run `cleanup.sh --help` for the full flag list. Defaults are overridable via
`CLEANUP_ROOT`, `CLEANUP_TMP_DAYS`, `CLEANUP_SCAN_DEPTH`.

## Tier model

**Safe (auto-applied, regenerable):**
docker build cache (`builder prune`), dangling images (`image prune`), exited
containers (`container prune` — running ones are inherently skipped), package
caches (`npm cache verify`, `uv cache prune`, `pip cache purge`, `pnpm store
prune`), and your own temp files older than `--days` (default 7).

**Aggressive (opt-in flag + confirmation):**
unused images (`--images`), dangling volumes (`--volumes`), stale branches
(`--branches`), worktrees (`--worktrees`), build artifacts (`--artifacts`),
killing stuck jobs (`--jobs --kill`).

## Guards & safety contract

These are enforced in the script and must never be loosened:

- **Never** `docker system prune -a --volumes`. Volumes are only touched via
  explicit `--volumes`, and volumes attached to running containers are kept.
- **Running compose projects are protected** — the report names them; the safe
  tier only removes *exited* containers and *dangling/unused build* layers.
- **A branch is deleted only if ALL hold:** upstream is `[gone]`, fully merged
  into the repo's default branch, has **zero** commits absent from every remote
  (`git rev-list --count <b> --not --remotes` = 0), is **not** the current
  branch, and is **not** checked out in any worktree. Uses `git branch -d`
  (refuses unmerged) — never `-D`.
- **Live worktrees are never auto-removed** — only already-deleted records are
  pruned; live ones are listed for manual removal.
- **Process killing is report-only by default.** With `--kill`, the script sends
  `SIGCHLD` to *reaping parents* of zombies and refuses PID 1, `sshd`,
  `dockerd`, `containerd`, `systemd`, and its own process tree.
- **Scheduled-job / agent directories are never targets** — the script only
  removes caches, build artifacts under an explicit `--artifacts PATH`, and your
  own old temp files.

## Diagnosing & fixing zombie (defunct) processes

Zombies are child processes that exited but were never `wait()`ed by their
parent. Each holds a PID slot; a growing count eventually exhausts PIDs and
always signals a subprocess leak. **You cannot kill a zombie — it's already
dead.** It clears only when its *parent* reaps it or the parent dies.

`cleanup.sh --jobs` does the diagnosis: it groups zombies by parent, maps each
parent to its **docker container**, and reads the container's **init** setting
(reported as `true`, `false`, or `<nil>` — `<nil>`/`false` both mean *no init →
needs the fix*).

The dominant cause on dev boxes is the **Docker PID-1 reaping problem**: an app
(e.g. `python -m app server run`) runs as **PID 1** inside a container with no
init. A real init reaps orphaned grandchildren; a plain app as PID 1 only reaps
what it explicitly waits on — so orphaned children accumulate as `<defunct>`.

**Fix hierarchy (the skill prints the specific one per service):**
1. **Permanent:** add `init: true` to the service in `docker-compose.yml` (or
   `docker run --init`, or bake `tini`/`dumb-init` as the entrypoint). PID 1
   becomes a reaper — zero app changes.
2. **Clear now:** `docker restart <service>` (or `cleanup.sh --jobs
   --restart-parents`) — zombies die with the parent. This restarts a **running**
   service (e.g. an auth/gateway container), so it causes brief downtime and can
   disrupt other in-flight work; the script prompts per container.
3. **App-level (if `init: true` and zombies persist):** the app double-forks or
   leaks subprocesses — fix it to `proc.wait()` / `subprocess.run()` / `.join()`
   workers, or set `signal(SIGCHLD, SIG_IGN)`.
4. **SIGCHLD nudge** (`--kill`): cheap but only works if the parent *has* a
   handler it failed to run — usually a no-op for servers that never `wait()`.

Non-containerized zombie parents and orphaned long-lived dev servers (vite,
uvicorn, pytest, playwright…) are also listed for manual review; the skill never
kills application processes automatically.

## Recipes

```bash
# Free disk fast (report, then auto-clean the safe tier)
cleanup.sh

# See exactly what would happen, change nothing
cleanup.sh --dry-run

# Deep reclaim including unused images + dangling volumes (CI-safe, no prompts)
cleanup.sh --images --volumes -y

# Tidy a repo's merged branches after a sprint
cleanup.sh --branches --repo .

# Reclaim a heavy build tree
cleanup.sh --artifacts ./frontend

# Diagnose zombies (root cause + per-service fix), then clear definitively
cleanup.sh --jobs
cleanup.sh --jobs --restart-parents     # restart container parents to reap them
```

## Common mistakes

| Mistake | Why it's wrong | Do instead |
|---|---|---|
| `docker system prune -a --volumes` | Destroys named DB volumes + images of **running** stacks. | `cleanup.sh` (safe) or `--images`/`--volumes` with the guards. |
| `git branch -D` to "clear local branches" | Silently drops branches with unpushed commits. | `cleanup.sh --branches` (only gone+merged+pushed, uses `-d`). |
| `rm -rf` a worktree directory | Leaves dangling git metadata / loses uncommitted work. | `cleanup.sh --worktrees` lists them; remove via `git worktree remove`. |
| `kill -9` a zombie | Zombies are already dead; killing does nothing. | `cleanup.sh --jobs` finds the non-reaping parent; restart it or add `init: true`. |
| Restarting containers to "clear zombies" forever | Treats the symptom; they return. | Add `init: true` to the service (permanent reaper). |
| Pruning while a stack is up | Removes layers/volumes the running stack depends on. | Report first; safe tier skips running containers/volumes. |

## Portability

The script hardcodes no paths, usernames, repo names, branch names, or services.
It discovers repos under `--root`, resolves each cache via the tool's own config
(`npm config get cache`, `uv cache dir`, `pip cache dir`, `$XDG_CACHE_HOME`),
and probes every tool with `command -v` — absent tools are skipped, never fatal.
Safe to commit to a repo and drop into any worker's `~/.claude/skills`.
