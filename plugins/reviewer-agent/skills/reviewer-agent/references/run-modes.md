# Run modes

All three share the same per-PR state machine; they differ only in the loop driver
and how "wait for a new PR" is realized. Because state lives on the PR, the driver is
stateless and every fire is idempotent (a fire with no eligible PRs exits in seconds).

## `loop` (in-session watch) — DEFAULT
GitHub does not push PR events to a local agent (that needs a webhook — see below), so
"watch" means **continuous low-latency polling**, not a fixed long interval. Drain the
queue once, then keep a `Monitor`-backed **watcher** running that reacts within
`watch_interval` (default **60s**) — not a 15-minute lag. The watcher emits one event
per new/changed PR; process each immediately, then it goes back to watching.

```bash
# run under the Monitor tool — emits a line per new/changed PR across the target repos
declare -A seen
while true; do
  for R in $REPOS; do
    while read -r n sha; do
      [ "${seen[$R#$n]:-}" = "$sha" ] || { echo "$R #$n $sha"; seen[$R#$n]=$sha; }
    done < <(gh pr list --repo "$R" --state open --json number,headRefOid \
             --jq '.[]|"\(.number) \(.headRefOid)"')
  done
  sleep "${WATCH_SECONDS:-60}"
done
```
Polling stays cheap: each `gh pr list` is a few KB, and for many repos you can drop to
GitHub's conditional-request path (`gh api …/pulls --cache` / `If-None-Match` ETag — a
`304` is free and doesn't count against the rate limit). Tighten `watch_interval` for
faster reaction, loosen it to save calls.

**Idle fallback / heartbeat:** if the `Monitor` tool isn't available, fall back to
`ScheduleWakeup` — re-arm `/review-prs <args>` verbatim every `poll_interval` (default
15m → ~900s; ≤270s keeps the prompt cache warm). Equivalent shortcut: `/loop
/review-prs <args>`. Keep going until the user interrupts or the kill-switch
(`reviewer-agent: PAUSED`) trips. Loop is **session-bound** (dies with the session) —
use `cron` to survive that, or a webhook for true push.

### True push — webhooks (optional, near-instant, needs a receiver)
For zero-latency reaction, register a GitHub **webhook** (PR events) pointing at a small
receiver that runs `/review-prs <repo> --mode once` on each `pull_request` /
`pull_request.synchronize` event. The receiver needs a public endpoint — a tiny server,
or a tunnel (`smee.io`, `cloudflared tunnel`, `ngrok`). This trades infra for instant
reaction; the polling watch above needs none. (Not shipped in v0.1 — ask to add it.)

## `once` (single pass)
Run one pass: `select-prs.sh` → process each candidate sequentially (concurrency 1) →
exit when the queue is exhausted. Print a run summary. No re-arm, no "wait for new PR".
Use it for a one-shot sweep or when an external scheduler re-invokes the CLI.

## `cron` (durable, survives session exit)
Schedule a durable recurring job:
```
CronCreate(cron="*/15 * * * *", recurring=true, durable=true,
           prompt="/review-prs --repo <R> --mode once --phase merge")
```
Each fire enqueues a fresh single pass; idempotency makes empty fires cheap.
`CronList` / `CronDelete` manage it; `/review-prs --mode cron --stop` → `CronDelete`.

**Caveats / fallbacks (these are optional harness tools — degrade gracefully):**
- Recurring `CronCreate` jobs auto-expire after ~7 days → re-arm, or use the
  `schedule` skill's remote routines for a server-side job that survives the box being
  off. `CronCreate(durable)` only means "survives this session."
- Where `CronCreate`/`Monitor`/`ScheduleWakeup` aren't available, fall back to an OS
  scheduler invoking the CLI headless, e.g.
  `*/15 * * * * cd <repo> && claude -p "/review-prs --repo <R> --mode once --phase merge"`,
  or a GitHub Actions `schedule:` workflow that runs the same command. Either way the
  on-PR state keeps every fire idempotent.

## Concurrency
Fixed at 1 PR at a time per agent (shared docker stack + git tree). Throughput across
machines comes from multiple agents, each serial, coordinating via the PR-level
advisory lock (see `safety.md`). For v0.1, prefer a **single** scheduler/machine;
multi-machine is best-effort and documented as such.
