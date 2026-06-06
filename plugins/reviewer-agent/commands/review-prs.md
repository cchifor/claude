---
description: Headless — review and merge the open PRs of a GitHub repo (or every repo under an owner). Analyze → fix → Codex review → docker validate → merge to main.
argument-hint: <github-url | owner | owner/repo> [--mode once|loop|cron] [--validation-level slim|full] [--merge-policy auto|escalate]
---

Run the **reviewer-agent** headlessly over `$ARGUMENTS`. Use the `reviewer-agent` skill (Skill tool) and follow its per-PR state machine exactly. **Do not ask the user anything** — run independently with defaults.

## Target (first positional arg — required)
The first non-`--flag` token is the target. Normalize it with
`"$RA/resolve-target.sh" "<target>"` → `{scope, owner, repos:[...]}`. Accepted forms:
- `https://github.com/cchifor/platform/pulls` or `…/platform` or `cchifor/platform` → that repo.
- `https://github.com/cchifor` or `cchifor` → **every** non-archived source repo under that owner.

## Defaults (no flags needed)
- **mode = loop** (drain the open-PR queue, then keep re-polling every `poll_interval` (default 15m) and processing new/changed PRs — runs independently until you stop it or a kill-switch trips). `--mode once` = single pass then exit; `--mode cron --every 15m` = durable job that survives session exit.
- **phase = merge** (full pipeline incl. merge to main — no dry-run).
- validation_level = `slim`, merge_policy = `auto` (native auto-merge where available, gated direct merge otherwise).
- Caps are generous backstops (`max_prs_per_run`/`max_merges_per_run` = 50); the real safety is the per-PR gate (validation green + Codex converged + all checks green on the SHA), not the counts.

## Procedure
1. `"$RA/detect-tooling.sh"` (confirm gh authed; note codex/docker). `RA="${CLAUDE_PLUGIN_ROOT}/skills/reviewer-agent/scripts"`.
2. `"$RA/resolve-target.sh" "<target>"` → the repo list. Pass any extra `--key value` flags through to `resolve-config.sh`.
3. **One pass** = for each repo in the list:
   a. `"$RA/resolve-config.sh" --repo <repo> [pass-through flags] > $CFG`.
   b. `"$RA/pr-state.sh" bootstrap --repo <repo>`. Honor the kill-switch (a `reviewer-agent: PAUSED` issue/label).
   c. Loop: `"$RA/select-prs.sh" --repo <repo> --config-file $CFG`; for each candidate run the per-PR pipeline from `references/state-machine.md` (claim → isolate → `pr-fixer` → `gh-merge.sh --verdict-file …` → record). Repeat until `select-prs` returns no eligible PRs (drain the queue), respecting the caps.
4. Print a per-repo summary (processed / merged / escalated / skipped-with-reason).
5. **Keep watching (mode = loop, default):** after the drain, start the `Monitor`-backed watcher from `references/run-modes.md` over the target repos — it reacts within `watch_interval` (~60s), emitting an event per new/changed PR; process each immediately, then it resumes watching. This is the "watch GitHub" path (GitHub can't push to a local agent without a webhook — see run-modes.md). If `Monitor` is unavailable, fall back to re-arming `/review-prs $ARGUMENTS` via `ScheduleWakeup` every `poll_interval`. Stop on user interrupt or kill-switch. For `--mode once`: skip step 5 (exit). For `--mode cron`: create a durable `CronCreate` job (see `references/run-modes.md`) and exit.

Merging is autonomous by default; per-PR safety gates still block any PR that isn't validated green, Codex-converged, and all-checks-green on the exact head SHA. Fork/untrusted PRs are review-only. To preview without writing, add `--phase dry-run`.
