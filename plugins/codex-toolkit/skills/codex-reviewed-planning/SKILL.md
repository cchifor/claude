---
name: codex-reviewed-planning
description: Use when the user asks for a plan/design and wants it reviewed by a second model before implementation. Drives the Opus↔Codex feedback loop - drafts a plan to <repo>/plans/, dispatches the codex subagent (profile=plan-review, gpt-5.5/xhigh, read-only) to emit a reviewed copy with inline feedback, Opus writes it back, iterates up to 2 rounds, then converges or escalates.
---

# Codex-Reviewed Planning

Encodes the Opus↔Codex feedback loop for plan review. You draft → Codex critiques (read-only output) → you apply the critique to the plan and respond → either iterate or implement. Git commits are the rendezvous — no PRs needed during iteration.

## Why "Opus writes" and not "Codex writes"

On Windows + codex v0.130, the sandbox is **always effectively read-only** regardless of profile or CLI flags (the `elevated_windows_sandbox` and `experimental_windows_sandbox` features are both `removed` in `codex features list`). Only `--dangerously-bypass-approvals-and-sandbox` allows writes, and that flag is forbidden by `~/.claude/agents/codex.md`. So: **Codex emits the reviewed content as its final message; Opus reads it from `--output-last-message` and writes the plan file + commits.** When Windows sandbox support is restored, flip `sandbox_mode = "workspace-write"` in `~/.codex/config.toml` `[profiles.plan-review]` and the skill body can be simplified to a cherry-pick.

## When this applies

Use this skill when:
- The user asks for a plan/design AND explicitly mentions Codex review / second opinion
- The user asks for a plan AND it's non-trivial (multi-file, multi-step, architectural)
- The user is choosing between competing approaches and wants an independent perspective

Skip for:
- Trivial single-step plans (token waste — see `[[feedback_codex_windows_sandbox]]`)
- Bug-fix plans where the root cause is already obvious
- Plans on `main` or other shared branches (refuse; require a feature branch)

## Pre-flight checklist

Create one TodoWrite item per check:

1. **Branch check** — confirm `git branch --show-current` is NOT `main` or `master`. If it is, refuse and ask the user to create a feature branch first.
2. **Clean tree** — confirm `git status --porcelain` is empty. A dirty tree mixes Opus's edits with the review trail. Ask the user to commit or stash.
3. **Plans dir** — confirm `<repo>/plans/` exists. If not, create it and commit a `.gitkeep`.
4. **Codex available** — confirm `codex --version` returns 0.130+. If not, halt and ask the user to update.

## The loop

Create one TodoWrite item per step. Update status as you go.

### Step 1 — Draft the plan

Write the plan to `<repo>/plans/YYYY-MM-DD-<slug>-plan.md`. Use this template:

```markdown
# <Plan title>

## Context
<why this change>

## Approach
<what to do — recommended path only, not all alternatives>

## Critical files
<paths to be modified, with brief role of each>

## Verification
<how to test end-to-end>

<!-- codex-review-status: pending -->
```

Commit on the current feature branch:

```bash
git add plans/<file>
git commit -m "plan: draft <slug>"
```

### Step 2 — Dispatch Codex (read-only review)

Invoke the codex subagent with the plan-review profile. Codex reads the plan and **emits the reviewed content as its final message** (it cannot write because Windows sandbox is read-only). Prompt template:

```
Read plans/<plan-file>.md in your current worktree. Review it for: missed edge
cases, incorrect assumptions, over-engineering, missing verification steps,
security concerns, scope creep, hidden dependencies, integration risks.

Output the ENTIRE reviewed plan file as your final message - this output will
be written back to the plan file verbatim. Format:

  - Keep the original title and all original sections intact.
  - Insert a "## Codex Review" section directly after the title with a 3-5
    bullet high-level summary (what's good, what concerns you, what's missing).
  - Add `<!-- codex: <concise critique> -->` HTML comments on the line or
    section where each specific issue applies. One comment per distinct issue.
    Keep each comment to one or two sentences.
  - Replace `<!-- codex-review-status: pending -->` with
    `<!-- codex-review-status: complete -->`.

If the plan already contains `<!-- opus-pushback: ... -->` markers from a
previous round, you MUST respond to each — either:
  - Drop the original concern: delete your matching `<!-- codex: ... -->`
    line so neither marker remains.
  - Strengthen it: replace your original with `<!-- codex: round-N:
    <new reasoning that engages the pushback> -->`.

Do NOT include any text other than the reviewed file content. Do NOT wrap
the output in code fences. Your message IS the new file content.
```

Dispatch via:

```
Agent(subagent_type="codex", prompt="profile=plan-review. <the prompt above with placeholders filled in>")
```

The dispatcher creates a sibling worktree off HEAD (so Codex sees the committed plan), runs `codex exec --profile plan-review`, captures the final message to `--output-last-message`, and returns a structured summary including the worktree path and the path to the captured output file.

### Step 3 — Apply Codex's output to the plan file

The dispatcher's return includes the contents of Codex's `--output-last-message` (the reviewed file content). Write it to the plan file in your main worktree:

```python
# Conceptually:
new_content = <verbatim contents of Codex's output>
Write(plan_path, new_content)
```

Commit attributing the review to Codex (no AI co-author trailer — keep commits clean per `[[feedback_no_claude_code_references]]`):

```bash
git commit -am "codex: review round N of <slug>"
```

### Step 4 — Classify and respond

Read the plan file. For each `<!-- codex: ... -->` marker, decide:

- **ACCEPT** — Codex is right. Edit the plan to resolve the concern. Delete the marker.
- **PUSHBACK** — You disagree with the reasoning. Replace the marker with `<!-- opus-pushback: <your counter-reasoning, one to two sentences> -->`. Leave Codex's original `<!-- codex: ... -->` line directly above for the next round (Codex needs context).
- **ESCALATE** — Judgment call the user should weigh in on. Use `AskUserQuestion` with the contested point. Apply their choice.

Strip the `## Codex Review` summary section once you've decided on every bullet (it served its purpose).

Commit:

```bash
git commit -am "opus: address codex review round N of <slug>"
```

### Step 5 — Decide: iterate, escalate, or converge

- If any `<!-- opus-pushback: ... -->` markers remain AND `round < 2` → goto Step 2 with a prompt that explicitly references the pushbacks.
- If `round == 2` and disagreements remain → escalate to the user via `AskUserQuestion`. Two LLMs disagreeing twice means it's a judgment call, not a fact gap.
- If no markers remain → converge.

### Step 6 — Finalize and hand off

Strip any remaining review markers. Change `<!-- codex-review-status: complete -->` to `<!-- codex-review-status: finalized -->`. Commit:

```bash
git commit -am "plan: finalize <slug>"
```

Then offer the user three options via `AskUserQuestion`:
- **Open a PR** for human review of the converged plan
- **Start implementation** now (hand off to `superpowers:executing-plans`)
- **Both** — open PR and start implementation in parallel

## Convergence rule (hard cap)

**Max 2 review rounds.** Round 3 is forbidden. If two rounds haven't converged, the disagreement is judgment, not fact — escalate. Without this cap, two LLMs will ping-pong on taste forever and burn tokens.

## Anti-patterns

| Red flag thought | Reality |
|---|---|
| "I'll just iterate one more round to be sure" | No. The 2-round cap exists for a reason. Two LLMs will agree on facts and ping-pong on taste forever. Escalate. |
| "Codex is wrong, let me ignore that comment" | No. If you disagree, add an explicit `<!-- opus-pushback: ... -->` with your reasoning. The audit trail is the value. |
| "Let me edit the file without going through git" | No. Every change is a commit. The trail IS the deliverable. |
| "Let me just bypass the sandbox to let Codex write directly" | No. `--dangerously-bypass-approvals-and-sandbox` is forbidden by the codex agent. Opus-writes is the supported pattern on Windows v0.130. |
| "Let me dispatch for this trivial one-step plan" | No. Token cost. Skip the skill for trivial work. |
| "Let me dispatch with the writer (default) profile instead" | No. Use `plan-review` specifically — it has the right model + effort combo and the dispatcher recognizes it. |
| "The user didn't ask for codex review, but I'll do it anyway" | Only if the plan is clearly non-trivial. For small plans, just write the plan directly. |

## What this skill does NOT do

- Does NOT call codex itself — dispatches the existing `codex` subagent.
- Does NOT have Codex commit changes (Windows sandbox blocks writes).
- Does NOT replace `superpowers:writing-plans` — it's the codex-augmented variant. Cross-link, don't duplicate.
- Does NOT open PRs during iteration — only optionally at convergence.

## Cross-references

- `superpowers:writing-plans` — upstream pattern for drafting plans. Same template; this skill adds the review loop on top.
- `superpowers:executing-plans` — downstream pattern. Hand off here after convergence.
- `superpowers:requesting-code-review` / `superpowers:receiving-code-review` — sibling patterns for non-plan code review.
- `~/.claude/agents/codex.md` — the underlying dispatcher.
- `~/.codex/config.toml` `[profiles.plan-review]` — the model + effort + sandbox config.
- `[[feedback_codex_windows_sandbox]]` — the Windows-sandbox constraint that drives Opus-writes pattern.
