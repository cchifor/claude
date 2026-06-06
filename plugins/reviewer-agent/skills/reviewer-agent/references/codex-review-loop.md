# Codex cross-review loop (Linux-native)

Reuses `codex-toolkit:codex-reviewed-planning`'s Phase-B discipline — inline
`<!-- codex: … -->` markers, ACCEPT/PUSHBACK/ESCALATE classification, **hard cap of
2 rounds**, escalate on persistent disagreement — applied to the PR fix diff.

## Invocation (this machine is Linux, not the Windows dispatcher)
The bundled `codex` dispatcher agent is **Windows-specific** (`cmd /c … < NUL`,
forced read-only sandbox, "Opus-writes" workaround). On Linux none of that applies.
Invoke codex directly:

```bash
CODEX="$(command -v codex || echo "$HOME/.npm-global/bin/codex")"   # absolute path; PATH may be empty in cron
"$CODEX" exec --sandbox read-only --skip-git-repo-check \
  --output-last-message "$WT/.ra/codex-review-r${ROUND}.md" \
  -C "$WT" - < "$WT/.ra/review-prompt-r${ROUND}.txt" > "$WT/.ra/codex-r${ROUND}.log" 2>&1
```

- **Do NOT pin a model or `--profile review`.** That profile pins `gpt-5.3-codex`,
  which a ChatGPT-account Codex rejects (`400 … model not supported`). Use the
  default model with `--sandbox read-only` (verified working: it runs `gpt-5.5`).
- Prompt via `-` on stdin from a file (clean multi-line; EOF arrives naturally — no
  `< NUL` needed on Linux).
- Capture the verdict via `--output-last-message`; capture stdout/stderr to a log.

## The loop
```
PRE_FIX_SHA = the PR head before the agent's commits
for ROUND in 1..codex_round_cap (default 2):
  build review-prompt-r${ROUND}: the code-reviewer.md template + the original issue
    list + `git -C $WT diff $PRE_FIX_SHA..HEAD`; ask codex to verify each blocking
    issue is resolved and emit findings as `<!-- codex: <critique> -->` markers with a
    **Severity:** line each, ending `<!-- codex-impl-review-status: complete -->`.
  run codex (above); parse markers (grep '<!-- codex:').
  classify each: ACCEPT -> edit + commit `fix(...): … — addresses codex review`,
    remove marker; PUSHBACK -> replace with `<!-- ra-pushback: <reason> -->`;
    ESCALATE -> record for the escalation path.
  if no blocker/important markers remain -> CONVERGED (codex.converged=true) -> validate.
  if ROUND == cap and disagreements remain -> ESCALATE (do not do round 3).
```

## Degraded
If `codex` is absent: skip the loop, do a self-review with the `code-reviewer.md`
template, set `codex.converged=false`, and note "codex unavailable" in the PR summary.
Because the merge gate requires `codex.converged=true`, a degraded review means the PR
is pushed/fixed but **not merged** — it escalates for a human, unless the operator
overrides.

Keep the review trail (markers, logs) under `$WT/.ra/` (inside the throwaway worktree;
removed at S9). Never commit `.ra/` artifacts.
