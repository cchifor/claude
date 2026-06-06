# Configuration

Resolved by `resolve-config.sh` into one JSON blob consumed by every script.

**Precedence (low → high):**
`built-in defaults  <  base-branch .reviewer-agent.yml  <  REVIEWER_AGENT_* env  <  CLI flags`

The repo config file is read from the **trusted base branch** via the GitHub API
(`repos/<repo>/contents/.reviewer-agent.yml?ref=<base>`) — **never** from a PR
checkout, so a PR can't change how it is reviewed. A PR diff that modifies
`.reviewer-agent.yml` is treated as an escalation, not an input.

`.reviewer-agent.yml` is optional. v0.1 parses **flat scalar keys** and **inline
lists** (`key: [a, b]`); block lists (`- item` on following lines) are not parsed —
use the inline form.

## Keys

| Key | Default | Meaning |
|---|---|---|
| `repo` | (required) | `owner/repo`, a GitHub URL (`https://github.com/owner/repo[/pulls]`), or bare `owner` (→ every non-archived source repo, expanded by `resolve-target.sh`). Positional arg, `--repo`, or `REVIEWER_AGENT_REPO`. |
| `base_branch` | repo default | Merge target; also where config is read from. |
| `local_clone` | — | Path to a local clone used for worktrees (e.g. `/workspace/c4/platform`). If empty, clone on demand. |
| `mode` | `loop` | `loop` (drain, then re-arm next pass via `ScheduleWakeup` every `poll_interval` — **default**) \| `once` (single drain then exit) \| `cron` (durable `CronCreate`, survives session exit). |
| `phase` | `merge` | `merge` (full pipeline incl. merge to main — default, headless) \| `fix` (push, no merge) \| `dry-run` (report only). |
| `dry_run` | `false` | Alias for `phase=dry-run`. |
| `poll_interval` | `15m` | `cron` cadence; also the `loop` idle-heartbeat fallback when the live watcher is unavailable. |
| `watch_interval` | `60s` | `loop` live-watch cadence (Monitor reaction time to a new/changed PR). Tighten for faster reaction, loosen to save API calls. |
| `merge_policy` | `auto` | `auto` = native auto-merge where available, else **direct merge** (the default fallback). `escalate` = never merge directly; hand off. |
| `merge_method` | `squash` | `squash` \| `merge` \| `rebase`. |
| `delete_branch` | `false` | Delete the head branch on merge (same-repo only). |
| `trust` | `same-repo` | Who gets local execution + merge. `same-repo` = non-fork PRs. Forks are always review-only. |
| `authors_allowlist` | `[]` | If non-empty, a full-mode PR's author must be listed (else review-only). |
| `expected_checks` | `[]` | Named checks/workflows that MUST be present and green before a direct merge. Closes the "no required checks on an unprotected repo" gap — set these on repos without branch protection. |
| `allow_no_checks` | `false` | If `true`, permit merging a PR that has **zero** status checks. Leave `false` to refuse merging without CI signal. |
| `codex_round_cap` | `2` | Max Codex cross-review rounds (hard cap). |
| `validation_cap` | `2` | Max fix↔validate retries before escalating. |
| `validation_cmd` | — | Explicit override command (run in the checkout). Highest-priority validation source. |
| `validation_level` | `slim` | `unit` \| `slim` \| `full`. Picks the validation ladder rung / compose profiles. |
| `validation_timeout` | `1800` | Outer per-run validation timeout (seconds). |
| `include` / `exclude` | `[]` | Label-name lists; a PR must match `include` (if set) and must not match `exclude`. |
| `protected_paths` | `.github/`, `infra/`, `CODEOWNERS`, `scripts/up.sh`, `secrets/`, `.reviewer-agent.yml` | A PR touching any of these escalates (no auto-edit, no merge). |
| `max_prs_per_run` | `50` | PRs processed per pass (runaway backstop, not a safety gate). |
| `max_merges_per_run` | `50` | Merges per pass (runaway backstop). Per-PR gates are the real safety. |
| `lock_ttl_seconds` | `3600` | Advisory-lock TTL; must exceed the longest run (heartbeat refreshes it). |
| `concurrency` | `1` | Fixed at 1 (shared docker stack + git tree). |

## Examples
```
# .reviewer-agent.yml on the base branch
validation_level: slim
expected_checks: [ci, smoke, frontend]
merge_method: squash
exclude: [dependencies, wip]
```
```
REVIEWER_AGENT_REPO=cchifor/platform \
  /review-prs --mode cron --every 15m --validation-level slim
```
