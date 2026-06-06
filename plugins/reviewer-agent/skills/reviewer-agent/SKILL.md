---
name: reviewer-agent
description: Use when asked to monitor, review, fix, or auto-merge the open pull requests of a GitHub repo, watch a repo's PR queue, "babysit PRs", keep a repo's PRs green, or run an autonomous PR-fixing agent on a schedule. Repo is a parameter.
---

# reviewer-agent

Drive every open PR of a configured repo toward a clean, mergeable state — **one
PR at a time**, source of truth on the PR, never bypassing branch protection.

## Preflight (always, before touching any PR)
1. Resolve scripts: `RA="${CLAUDE_PLUGIN_ROOT}/skills/reviewer-agent/scripts"` (or the `scripts/` dir beside this file).
2. `"$RA/detect-tooling.sh"` — confirm `gh` (authed), and note `codex`/`docker` (degrade per `references/portability.md`).
3. **Resolve the target** (a GitHub URL / `owner` / `owner/repo`): `"$RA/resolve-target.sh" "<target>"` → `{scope, repos:[...]}`. An `owner` target expands to every non-archived source repo under it. Then process each repo below.
4. Per repo: `"$RA/resolve-config.sh" --repo <repo> [flags] > $CFG` — config from **base branch**, env, flags (repo config read from the trusted base branch, never a PR checkout). Default `phase=merge` (headless, full pipeline incl. merge); pass `--phase dry-run` only to preview.
5. `"$RA/pr-state.sh" bootstrap --repo <repo>`; **kill-switch:** if a `reviewer-agent: PAUSED` issue/label exists, stop.

## Run-mode dispatch (default = loop)
| Invocation signal | Mode | Action |
|---|---|---|
| default · "keep watching/merging" · `--mode loop` | live watch **(default)** | drain, then a `Monitor` watcher reacts to new/changed PRs within `watch_interval` (~60s); `ScheduleWakeup`/`poll_interval` is only the idle fallback. Stop on interrupt/kill-switch — see `references/run-modes.md` |
| `--mode once`, "current PRs then stop" | single-pass | one drain over `select-prs.sh`, exit |
| `--mode cron --every N`, "survive session exit" | scheduled | durable `CronCreate` — see `references/run-modes.md` |

## Per-PR pipeline — **REQUIRED: follow `references/state-machine.md` in order**
`select → claim → isolate → analyze → baseline → fix → codex cross-review → validate → push → merge → record`.
Do not skip baseline reproduction. Do not skip validation. Do not merge by hand — use `scripts/gh-merge.sh`.

## Cross-review — **REQUIRED sub-skill**
Use `codex-toolkit:codex-reviewed-planning`'s 2-round loop for the fix review. Linux-native codex invocation in `references/codex-review-loop.md` (do **not** pin a model/profile).

## More detail (load on demand)
`references/{state-machine,run-modes,validation,configuration,portability,safety,codex-review-loop}.md`.

## Red flags — STOP
- Never merge with `gh pr merge` directly — only via `scripts/gh-merge.sh` (it gates checks + SHA).
- Never merge when checks are zero/pending/failing, mergeable≠MERGEABLE, Codex unconverged, or validation degraded.
- Never `--admin`-merge, never force-push, never run untrusted **fork** PR code locally (review-only).
- Never run `mise run e2e:up`/`up`/`down` directly (they use the dev's default compose project) — validation goes through `scripts/validate.sh` (isolated `-p` project).
- Never read validation config from a PR checkout. Never exceed 2 Codex rounds.
