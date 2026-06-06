# Portability & install

The skill bakes in **no machine assumptions** — `detect-tooling.sh` re-derives every
tool's presence, version, and absolute path per machine, and sets PATH explicitly for
cron (where login-shell PATH is absent — e.g. `codex` lives at
`$HOME/.npm-global/bin/codex`). Internal references use the `scripts/` dir beside the
skill (`${CLAUDE_PLUGIN_ROOT}/skills/reviewer-agent/scripts`), never hardcoded paths.

## Degrade matrix
| Missing | Behaviour |
|---|---|
| `gh` / not authed | **Hard stop.** `gh auth login` (needs `repo` write scope). |
| `codex` | Skip Codex loop, self-review, `converged=false` → no merge; escalate. |
| `docker` / daemon down / can't isolate | No local stack validation; unit-only (`partial`) → no merge; escalate. |
| `mise` | Fall down the validation ladder (compose / Makefile / unit). |
| native auto-merge unsupported | Direct-merge fallback (`merge_policy=auto`, default) or escalate. |
| `CronCreate`/`Monitor`/`ScheduleWakeup`/`EnterWorktree` | Optional harness tools — fall back to git worktrees + OS cron / GitHub Actions (see `run-modes.md`). |

## Codex model caveat
Never pin `--profile review` / a specific model: `gpt-5.3-codex` is rejected on
ChatGPT-account Codex auth. Use the default model with `--sandbox read-only`
(see `codex-review-loop.md`).

## Auth & attribution (surface this to operators)
The agent acts **as whoever `gh` is authenticated as** on that machine. Every commit,
comment, label, and merge is attributed to that operator and uses their permissions.
On another machine it acts as that operator — running reviewer-agent means PRs get
fixed, commented, and merged **under your name**. Required: `gh auth login` with `repo`
(write: push, merge, labels, comments) and `read:org` for org repos; **write access to
the repo** is mandatory for push/merge (read-only access → review-only globally).

## Install (on any machine)
1. Add the marketplace once (if not present):
   `/plugin marketplace add cchifor/claude`
2. Install + enable:
   `/plugin install reviewer-agent@chifor-claude`
3. Authenticate GitHub: `gh auth login` (scopes above).
4. Allowlist the **wrapper scripts** in `settings.json` (they are the safety boundary;
   do NOT allowlist raw `git push`/`gh pr merge`/`docker compose` as the safety story).
   See `INSTALL.md` at the plugin root for the exact `permissions.allow` block.
5. Optionally drop a `.reviewer-agent.yml` on the repo's base branch (see
   `configuration.md`).
6. Smoke-test with `--phase dry-run` before enabling `--phase merge`.
