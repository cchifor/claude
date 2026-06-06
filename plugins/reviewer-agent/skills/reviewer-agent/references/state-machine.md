# Per-PR state machine

One PR at a time. **State lives on the PR** (labels + one hidden marker comment),
so any machine / cron fire resumes correctly. `$RA` = the `scripts/` dir, `$CFG` =
the resolved-config file from `resolve-config.sh`.

Each cycle re-reads GitHub; it never trusts in-memory history. Run the steps in
order. The merge step is the only irreversible action — it goes through
`gh-merge.sh`, never a hand-typed `gh pr merge`.

## S0 — FETCH & SELECT
```
"$RA/select-prs.sh" --repo "$REPO" --config-file "$CFG"
```
Returns trust-classified, filtered, number-sorted candidates (each with `mode` =
`full` | `review-only`). Skipped PRs are logged to stderr with a reason. Take the
first candidate. If none → wait/exit per `run-modes.md`.

## S1 — CLAIM (lock)
```
"$RA/pr-state.sh" claim --repo "$REPO" --pr "$N" --sha "$HEAD_SHA"
```
- `{"action":"skip","reason":"done"}` → terminal at this exact head SHA; go to next PR.
- `{"action":"skip","reason":"locked"|"lost-race"}` → another worker owns it; next PR.
- `{"action":"claimed"}` → proceed. Start a **heartbeat**: call
  `pr-state.sh heartbeat` periodically during long validation so the lock TTL
  (`lock_ttl_seconds`, default 3600) never expires mid-run.

## S2 — ISOLATE
```
"$RA/git-ops.sh" worktree-add --clone "$LOCAL_CLONE" --pr "$N" --mode "$MODE" --head-ref "$HEAD_REF"
```
`full` → a worktree on the PR head branch (pushable). `review-only` (fork/untrusted)
→ a detached read-only worktree (never executed locally, never pushed). Record the
returned worktree path + head_sha.

## S3 — ANALYZE → S7 (dispatch the worker)
Dispatch the **`pr-fixer`** subagent (or run its steps inline) with `REPO, PR,
WORKTREE, HEAD_SHA, CFG, MODE, RA`. It performs: analyze → **baseline reproduce** →
fix (TDD where mandated) → Codex cross-review (2-round cap) → validate (isolated
compose) → push. It returns a structured verdict with `recommendation`:

| recommendation | meaning | next |
|---|---|---|
| `ready` | no blocking issues, baseline already green | S8 MERGE |
| `merge-ready` | fix pushed, validation green, Codex converged | S8 MERGE |
| `review-only` | fork/untrusted; comments posted | S9 RECORD (review-only) + escalate |
| `escalate` | stuck (see reason): validation can't go green, Codex unconverged, conflict, protected path, validation partial/degraded, codex/docker unavailable | S9 RECORD (needs-human) |

**Phase gate:** in `--phase dry-run` the worker reports only (no push); in
`--phase fix` it pushes but you skip S8; only `--phase merge` proceeds to S8.

## S8 — MERGE (only on `ready`/`merge-ready`, `--phase merge`)
Write the fixer's verdict to a file (`$VERDICT`) — it must contain
`{"mode":"full","validated_sha":"<sha>","validation":{"result":"green"},"codex":{"converged":true}}`
(the `pr-fixer` return JSON satisfies this). Re-read head SHA (final guard), then:
```
"$RA/gh-merge.sh" --repo "$REPO" --pr "$N" --sha "$VALIDATED_SHA" --config-file "$CFG" --verdict-file "$VERDICT"
```
`gh-merge.sh` is the boundary: it **re-verifies** the verdict (full mode, validation
green, Codex converged, SHA match), plus the fork guard, base-branch match, mergeable
state, and that **all** relevant checks are green on the exact SHA (zero checks →
escalate unless `allow_no_checks`). Outcomes: `merged` (direct) · `armed` (native
auto-merge enabled where supported) · `defer` (mergeable unknown / checks pending →
leave for the next cycle) · `abort` (head-moved / conflict / wrong-base) · `escalate`
(unsafe verdict, no checks, fork, or `merge_policy=escalate`). Trust its verdict;
never merge around it.

## S9 — RECORD & NEXT
```
"$RA/pr-state.sh" update  --repo "$REPO" --pr "$N" --json '<validation/codex/merge facts>'
"$RA/pr-state.sh" release --repo "$REPO" --pr "$N" --outcome <merged|fixed|review-only|needs-human> --sha "$VALIDATED_SHA" --summary-file <md>
"$RA/git-ops.sh" worktree-remove --clone "$LOCAL_CLONE" --worktree "$WORKTREE"
```
Only `merged` → outcome `merged`. `armed` and `defer` → outcome `fixed` (the PR is
still open; the next cycle re-checks and confirms the real merge — never mark
`merged` before GitHub reports it merged, or future cycles would skip a PR whose
auto-merge later failed). escalate paths → `needs-human` (with a `PushNotification`
if enabled). **After a real merge:** re-fetch the base branch
and re-evaluate the remaining candidates — the base moved and their checks may have
been canceled by CI concurrency. Honor `max_merges_per_run` (default 1) and
`max_prs_per_run`. Then go to the next PR.

## Decision branches (summary)
- **No issues + checks green** → S8 directly (`ready`).
- **No issues but checks red (infra/flake)** → escalate; never blind-merge.
- **Fork / untrusted** → review-only; comment, never execute/merge.
- **Validation fail (attributable, < cap)** → loop fix↔validate; at cap → escalate.
- **Codex unconverged at 2 rounds** → escalate (two models disagreeing twice is a
  judgment call).
- **Merge conflict / head moved** → escalate / defer; never auto-rebase, never force.
- **Native auto-merge unavailable** → direct merge by default (`merge_policy=auto`),
  else escalate.
