# Installing reviewer-agent

## 1. Install the plugin
```
/plugin marketplace add cchifor/claude      # if not already added
/plugin install reviewer-agent@chifor-claude
```
Then enable it (settings.json `enabledPlugins`):
```json
"reviewer-agent@chifor-claude": true
```

## 2. Authenticate GitHub
```
gh auth login          # scopes: repo (write), read:org for org repos
```
The agent acts **as whoever `gh` is authed as** — all commits, comments, labels, and
merges are attributed to that operator and use their permissions. Write access to the
repo is required for push/merge; read-only access degrades to review-only.

## 3. Permissions (the safety boundary is the wrapper scripts)
The mutating wrappers (`scripts/git-ops.sh`, `gh-merge.sh`, `validate.sh`,
`pr-state.sh`) validate their own arguments (reject `--force`/`--no-verify`/`--admin`,
pin refspecs, inject the compose project, re-check the head SHA) and run all
git/gh/docker mutations as their own child processes. So **allowlist the wrapper
invocations**, plus the read-only queries the agent runs directly — do NOT allowlist
raw `git push` / `gh pr merge` / `docker compose` as the safety story (a permission
glob is not a boundary — a trailing `--force` still matches it).

Add to `permissions.allow` in `~/.claude/settings.json`:
```json
"Bash(gh pr diff:*)",
"Bash(gh run view:*)",
"Bash(gh label list:*)",
"Bash(*reviewer-agent/skills/reviewer-agent/scripts/*.sh:*)"
```
(`gh pr view/list/checks/create` and `codex exec`, `git worktree` are typically
already allowed.) Adjust the script-path glob to your install path if your Claude
version's matcher is stricter about `*` — the scripts live under
`<plugin>/skills/reviewer-agent/scripts/`. Note: the wrappers' internal
`gh api` / `git push` / `docker compose` / `mise` calls run as **child processes**
of the allowlisted script, so they do **not** need their own allowlist entries —
which is exactly why a broad `Bash(gh api repos/*)` is intentionally omitted.

**Never** add: `git push --force`, `gh pr merge --admin`, `gh repo edit` /
branch-protection writes, or a blanket `Bash(gh:*)`. Never export `GH_TOKEN`.

## 4. Optional repo config
Drop `.reviewer-agent.yml` on the repo's **base branch** (read from there, never from a
PR). See the skill's `references/configuration.md`. For repos without branch
protection, set `expected_checks: [...]` so the direct-merge gate has real checks to
require.

## 5. Run it (headless — reviews and merges by default)
```
/review-prs https://github.com/cchifor/platform           # review + merge this repo's open PRs
/review-prs https://github.com/cchifor/platform/pulls     # same (pulls URL accepted)
/review-prs cchifor/platform                              # short form
/review-prs https://github.com/cchifor                    # every source repo under the owner
/review-prs https://github.com/cchifor/platform --mode cron --every 15m   # keep running unattended
/review-prs https://github.com/cchifor/platform --phase dry-run           # preview only (optional)
```
No flags are required — it drains the open-PR queue and merges what passes the gates.
Per-PR safety still holds: only PRs that validate green, converge with Codex, and have
all checks green on the exact head SHA are merged; fork/untrusted PRs are review-only.
