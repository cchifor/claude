# Safety, locking, escalation

This agent writes code, pushes, and merges to `main` unattended, and **executes PR
code locally** in a docker stack that may mount the host docker socket. The guardrails
below are not optional.

## Trust model
- **Trust gate.** Only **trusted PRs** are validated locally and merged: non-fork PRs
  (and, if `authors_allowlist` is set, by a listed author). **Fork / untrusted PRs are
  review-only** — analyzed and commented on, **never executed locally, never merged.**
  Rationale: running arbitrary PR code in a stack that mounts `/var/run/docker.sock`
  can compromise the host, not just the repo.
- **Config provenance.** Validation config is read from the trusted base branch only
  (see `configuration.md`). A PR that edits `.reviewer-agent.yml` or any
  `protected_paths` entry → escalate, never auto-edit, never merge.

## Hard gates (evaluated before any write)
1. **Kill-switch** — a `reviewer-agent: PAUSED` issue/label (repo-wide) or a
   `reviewer-agent:paused` label on the PR → halt.
2. **Dry-run** (`phase=dry-run`) — analyze + report only; log `[DRY-RUN] would: …` for
   every mutation; zero pushes/comments/merges.
3. **Drafts** skipped. **Forks** → review-only.
4. **Never force-push** (rejected non-ff → escalate). The wrappers refuse `--force`,
   `--no-verify`, `--no-gpg-sign`, `--amend`, `--admin` anywhere in their args.
5. **Protected-path PRs** escalate.
6. **Clean validation tree** — `validate.sh` works in a throwaway worktree + isolated
   compose project; teardown targets only that project.
7. **Merge preconditions (all required):** validation `green` with fresh evidence
   (test-runner exit 0), Codex `converged`, `mergeable == MERGEABLE`, and **all
   relevant checks green on the exact head SHA** (zero checks → escalate unless
   `allow_no_checks`). Degraded/partial validation or missing Codex → escalate, never
   merge. `gh-merge.sh` enforces these; never merge around it.
8. **Bounded actions** — `max_prs_per_run`, `max_merges_per_run` (default 1),
   `validation_cap`, Codex 2-round cap. No silent caps: every cap/skip logs a reason.

## Advisory cross-machine lock (`pr-state.sh`)
GitHub is the source of truth (no atomic CAS). Claim = add `processing` label + write
a `lock{worker, claimed_at, ttl_seconds, claim_sha}` block into the marker comment,
then **confirm-read** (last-writer-wins → the loser yields). A **heartbeat** refreshes
`claimed_at` during long runs; a lock with no heartbeat past `lock_ttl_seconds`
(default 3600, must exceed the longest run) is takeable, recorded as `takeover_from`.
Worst case = brief double-processing, made non-destructive by SHA-keyed pushes +
`--match-head-commit` on merge. Always re-read the head SHA immediately before merge.

## Escalation
On a stuck state, apply `reviewer-agent:needs-human` + a structured marker-comment
section (reason code + evidence: failing test tail / unresolved Codex markers / merge
state), optional `PushNotification`, then move to the next PR — never block the queue.
Reason codes: `cannot-go-green`, `codex-disagreement`, `codex-unavailable`,
`docker-unavailable`, `validation-partial`, `merge-conflict`, `head-moved`,
`no-checks`, `native-auto-merge-unavailable` (when `merge_policy=escalate`),
`protected-path`, `fork-no-push`, `insufficient-perms`, `push-rejected`.

## Failure-mode table
| Failure | Detection | Response |
|---|---|---|
| docker daemon down | `detect-tooling` / compose error | unit-only (`partial`) → no merge; escalate `docker-unavailable`. |
| codex absent | `detect-tooling` | self-review, `converged=false` → no merge; escalate `codex-unavailable`. |
| gh rate limit | API 403 secondary | back off; release the lock so another fire retries; exit cleanly. |
| push rejected (non-ff) | `git-ops push` nonzero | never force; re-fetch + re-evaluate; if still rejected → escalate `push-rejected`. |
| merge conflict | `mergeable==CONFLICTING` | escalate `merge-conflict`; no auto-rebase. |
| CI never finishes | `gh-merge` returns `defer` | leave armed/deferred; the next cycle re-checks; FYI comment after a long wait, not an escalation. |
| infinite fix loop | `validation_cap` hit / same failing signature | hard-stop; escalate `cannot-go-green` with evidence. |
| two agents race | confirm-read shows another worker | loser yields; SHA-keyed idempotency makes a brief overlap non-destructive. |
| stale lock | no heartbeat past TTL | takeover with `takeover_from` note. |
| kill-switch mid-run | PAUSED appears | finish nothing new, release the lock, exit. |
