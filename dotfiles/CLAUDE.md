# User-scope preferences

These rules apply to every project I work on. Project-level `CLAUDE.md` files
override anything here.

## Git commits

- **Conventional Commits**, imperative mood, 50-char subject line.
  Example: `fix(auth): handle empty refresh token`.
- **No AI co-author trailers.** No `Co-Authored-By: Claude ...`, no
  `Generated with Claude Code`, no `Co-Authored-By: Codex`. Commits look like
  I wrote them myself.
- Prefer **new commits** over `--amend`. Never `--no-verify`, never `--no-gpg-sign`.

## Anything pushed to GitHub

- No "Generated with Claude Code" footers in READMEs, PR descriptions, issue
  comments, or wiki pages.
- No "AI-assisted" notes. The work is mine; the tooling is an implementation
  detail.

## GitHub CLI

- Use `gh` for all GitHub work — never `git-credential-manager` or manual
  token plumbing. `gh` already has my auth stored.
- Do **not** export `GH_TOKEN` per-shell. The CLI handles auth itself.
- Don't reach for elevated repo admin permissions speculatively. If I need
  them for a specific operation, explain why first and ask.

## Tooling install

If a problem is on the assistant's side (missing tool, wrong path, etc.),
fix it on the assistant side — don't reframe it as "user should install X"
without explanation. If something genuinely needs to be installed on my
machine, say what and why.

## Test discipline

For new features: ship **unit + integration + e2e** tests. If you skip a
layer, state why. Manual scripts are not e2e tests. Never dismiss a red CI
as "unrelated" without evidence — read the log first.

## Release vs. deploy

"Shipped", "merged", "implemented" are merge events, not deploy events.
Before piling on backwards-compatibility or forced-migration arguments,
confirm whether the change is actually running in prod.

## Push back before pivoting

If I ask for something that would unwind a best-practice plan we already
agreed on, surface the trade-off and the alternatives first. Don't silently
re-plan.

## Codex on Windows (v0.130)

- `codex exec` hangs on stdin EOF when invoked from PowerShell — always wrap
  in `cmd /c "codex exec ... < NUL"` (or feed the prompt via a file with
  `-NoNewline`). See the `codex-toolkit` plugin's dispatcher for the
  canonical invocation.
- Codex's Windows sandbox is forced read-only regardless of profile or
  flags. **Never** use `--dangerously-bypass-approvals-and-sandbox`. For
  tasks where Codex needs to "write", capture its final message via
  `--output-last-message` and have Claude do the actual file write.

## Python typing changes

`ty` and unit tests can pass on host Python 3.14 yet fail at runtime in a
container running Python 3.13. Always docker-smoke any annotation changes
before claiming they pass.
