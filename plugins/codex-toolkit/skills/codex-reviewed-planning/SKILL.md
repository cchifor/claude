---
name: codex-reviewed-planning
description: Use when the user asks for a plan/design and wants it reviewed by a second model. Covers two phases - (A) plan review BEFORE implementation, and (B) implementation review AFTER implementation, against the finalized plan. Both phases use the same Opus<->Codex feedback loop - Opus drafts, Codex critiques in a read-only worktree and emits inline `<!-- codex: ... -->` markers, Opus addresses each marker and either iterates or converges, capped at 2 rounds per phase, then escalates to the user on persistent disagreement.
---

# Codex-Reviewed Planning

Encodes the Opus↔Codex feedback loop for plans *and* implementations. Two phases:

- **Phase A — Plan review.** You draft a plan → Codex critiques (read-only) → you apply the critique → iterate or converge → hand off to implementation.
- **Phase B — Implementation review.** After the plan has been implemented, Codex reviews the diff against the plan → you address each finding (code fix, pushback, or escalate) → iterate or converge → finalize.

Git commits are the rendezvous in both phases — no PRs needed during iteration.

## Why "Opus writes" and not "Codex writes"

On Windows + codex v0.130, the sandbox is **always effectively read-only** regardless of profile or CLI flags (the `elevated_windows_sandbox` and `experimental_windows_sandbox` features are both `removed` in `codex features list`). Only `--dangerously-bypass-approvals-and-sandbox` allows writes, and that flag is forbidden by `~/.claude/agents/codex.md`. So in both phases: **Codex emits the reviewed content as its final message; Opus reads it from `--output-last-message` and writes the artifact + commits.** When Windows sandbox support is restored, flip `sandbox_mode = "workspace-write"` in the relevant profile and both phases can be simplified to a cherry-pick.

## Phase detection (run this first)

The skill auto-detects which phase to enter based on what's already in `<repo>/plans/` and what's in git history. Before anything else, run:

1. Identify the slug from the user's request (or list `plans/*-plan.md` and ask if ambiguous).
2. Check the matching plan file's `<!-- codex-review-status: ... -->`:
   - **No plan file** → start Phase A from Step 1.
   - **`pending`** → resume Phase A from Step 2 (Codex hasn't reviewed yet).
   - **`complete`** → resume Phase A from Step 4 (Codex reviewed; address markers).
   - **`finalized`** → check git: `git log <finalize-commit>..HEAD --oneline`.
     - If the range is empty → tell the user "plan is finalized; nothing implemented yet" and offer Phase A re-review or hand-off.
     - If the range is non-empty → enter Phase B at Step 7.
3. If a matching `*-impl-review.md` already exists, check `<!-- codex-impl-review-status: ... -->`:
   - **`pending`** → resume Phase B from Step 9.
   - **`complete`** → resume Phase B from Step 10.
   - **`finalized`** → both phases are done; tell the user and stop.

## When this applies

**Use Phase A when:**
- The user asks for a plan/design AND explicitly mentions Codex review / second opinion.
- The user asks for a plan AND it's non-trivial (multi-file, multi-step, architectural).
- The user is choosing between competing approaches and wants an independent perspective.

**Use Phase B when:**
- A plan from Phase A is finalized AND implementation commits exist on the same feature branch.
- The user asks for a "review the implementation against the plan" or "did I miss anything".

**Skip the skill for:**
- Trivial single-step plans (token waste — see `[[feedback_codex_windows_sandbox]]`).
- Bug-fix plans where the root cause is already obvious.
- Plans on `main` or other shared branches (refuse; require a feature branch).
- Phase B against a plan that didn't go through Phase A (use `superpowers:requesting-code-review` for arbitrary code review instead).

## Pre-flight checklist (both phases)

Create one TodoWrite item per check:

1. **Branch check** — confirm `git branch --show-current` is NOT `main` or `master`. If it is, refuse and ask the user to create a feature branch first.
2. **Clean tree** — confirm `git status --porcelain` is empty. A dirty tree mixes Opus's edits with the review trail. Ask the user to commit or stash.
3. **Plans dir** — confirm `<repo>/plans/` exists. If not, create it and commit a `.gitkeep`.
4. **Codex available** — confirm `codex --version` returns 0.130+. If not, halt and ask the user to update.

---

# Phase A — Plan Review

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

### Step 6 — Finalize plan and hand off

Strip any remaining review markers. Change `<!-- codex-review-status: complete -->` to `<!-- codex-review-status: finalized -->`. Commit:

```bash
git commit -am "plan: finalize <slug>"
```

Then offer the user three options via `AskUserQuestion`:
- **Open a PR** for human review of the converged plan
- **Start implementation** now (hand off to `superpowers:executing-plans`)
- **Both** — open PR and start implementation in parallel

Tell the user: "When implementation is done, re-invoke this skill and it will run Phase B (codex review of the implementation against the plan)."

---

# Phase B — Implementation Review

Enter Phase B when phase detection found a finalized plan + non-empty `<finalize-commit>..HEAD` range. Create one TodoWrite item per step.

### Step 7 — Snapshot the implementation

Find the finalize-commit and the diff range:

```bash
finalize_sha=$(git log --grep="plan: finalize <slug>" --format=%H -1)
git log "$finalize_sha"..HEAD --oneline       # what's in scope
git diff "$finalize_sha"..HEAD --stat         # diff size
```

If `finalize_sha` is empty, the plan was never finalized — fall back to Phase A. If the diff range is empty (no commits since finalize), tell the user nothing is implemented yet and stop.

Record `finalize_sha` and the range; the next steps need both.

### Step 8 — Dispatch Codex (implementation review)

Invoke the codex subagent with the **`review` profile** (read-only, gpt-5.3-codex, medium effort — already configured in `~/.codex/config.toml`). Prompt template:

```
Read plans/<plan-file>.md (the finalized plan) in your current worktree.
Then read the implementation diff:

  git log <finalize-sha>..HEAD --oneline
  git diff <finalize-sha>..HEAD

Review the implementation against the plan for:
  - Bugs, race conditions, edge cases the code missed
  - Deviations from the plan (intentional simplifications vs unintentional drift)
  - Security issues (input handling, authz, secrets, injection)
  - Missing tests for the new behavior
  - Dead code or scope creep beyond the plan
  - Things the plan didn't cover that the implementation still should have

Output the ENTIRE review file content as your final message - this will be
written verbatim to plans/<slug>-impl-review.md. Format:

  # Implementation review — <slug> — round N

  <!-- codex-impl-review-status: pending -->

  ## Summary
  3-5 bullets: overall quality, biggest concerns, what's missing.

  ## Findings
  For each finding, add a section like:

  ### <short title>
  **Location:** <file:line> (or commit-sha if cross-file)
  **Severity:** blocker | important | nit
  <!-- codex: <one-or-two-sentence critique with suggested fix> -->

  ## Diff stat
  <paste output of `git diff <finalize-sha>..HEAD --stat` here verbatim>

If a previous round of plans/<slug>-impl-review.md exists with
`<!-- opus-pushback: ... -->` markers (provided below this prompt if so),
you MUST respond to each — either drop your original `<!-- codex: ... -->`
finding, or strengthen it with `<!-- codex: round-N: <new reasoning> -->`.

Do NOT include text other than the file content. No code fences around
the whole output. Your message IS the new file content.
```

Dispatch via:

```
Agent(subagent_type="codex", prompt="profile=review. <the prompt above with placeholders filled in>")
```

For round 2+, append the prior round's impl-review file content (with all `<!-- opus-pushback: ... -->` markers) to the prompt so Codex sees what you disagreed with.

### Step 9 — Write the impl-review file

The dispatcher returns Codex's `--output-last-message` content. Write it:

```python
Write("plans/<slug>-impl-review.md", <verbatim codex output>)
```

Commit:

```bash
git add plans/<slug>-impl-review.md
git commit -m "codex: impl-review round N of <slug>"
```

### Step 10 — Classify and address each finding

Read the impl-review file. For each `<!-- codex: ... -->` marker, decide:

- **ACCEPT** — Codex is right. **Edit the source code** to fix the issue, then delete the marker from the impl-review file. Commit the source fix separately so the diff stays clean:
  ```bash
  git commit -m "<type>(<scope>): <what changed> — addresses codex impl-review"
  ```
- **PUSHBACK** — You disagree (e.g., Codex misread context, found a non-issue, or proposed over-engineering). Replace the marker with `<!-- opus-pushback: <one-or-two-sentence counter-reasoning> -->`. Leave Codex's original `<!-- codex: ... -->` line directly above so the next round has context.
- **ESCALATE** — Judgment call (e.g., "should we add a feature flag here?"). Use `AskUserQuestion` and apply their choice.

Once every finding is classified, strip the `## Summary` section from the review file (it served its purpose).

Commit the review-file changes separately from any source code fixes:

```bash
git commit -am "opus: address codex impl-review round N of <slug>"
```

### Step 11 — Decide: iterate, escalate, or converge

- If any `<!-- opus-pushback: ... -->` markers remain AND `round < 2` → goto Step 8, including the current impl-review file in the prompt so Codex can respond to the pushbacks.
- If `round == 2` and disagreements remain → escalate to the user via `AskUserQuestion`. Two LLMs disagreeing twice on code is a judgment call — let the human decide.
- If no markers remain → converge.

### Step 12 — Finalize impl-review

Strip any remaining review markers. Change `<!-- codex-impl-review-status: complete -->` to `<!-- codex-impl-review-status: finalized -->`. Commit:

```bash
git commit -am "impl-review: finalize <slug>"
```

Then offer the user via `AskUserQuestion`:
- **Open / update the PR** so reviewers see both the plan, the implementation, and the codex review trail
- **Done** — return control with no further action

## Convergence rule (hard cap, per phase)

**Max 2 review rounds per phase.** Round 3 is forbidden in both Phase A and Phase B. If two rounds haven't converged, the disagreement is judgment, not fact — escalate. Without this cap, two LLMs will ping-pong on taste forever and burn tokens.

## Anti-patterns

| Red flag thought | Reality |
|---|---|
| "I'll just iterate one more round to be sure" | No. The 2-round cap exists for a reason. Two LLMs will agree on facts and ping-pong on taste forever. Escalate. |
| "Codex is wrong, let me ignore that comment" | No. If you disagree, add an explicit `<!-- opus-pushback: ... -->` with your reasoning. The audit trail is the value. |
| "Let me edit the file without going through git" | No. Every change is a commit. The trail IS the deliverable. |
| "Let me just bypass the sandbox to let Codex write directly" | No. `--dangerously-bypass-approvals-and-sandbox` is forbidden by the codex agent. Opus-writes is the supported pattern on Windows v0.130. |
| "Let me dispatch for this trivial one-step plan" | No. Token cost. Skip the skill for trivial work. |
| "Let me dispatch Phase A with the writer (default) profile instead" | No. Use `plan-review` specifically — it has the right model + effort combo and the dispatcher recognizes it. |
| "Let me dispatch Phase B with `plan-review` since it worked for Phase A" | No. Phase B uses `review` (gpt-5.3-codex, medium effort) — it's tuned for reading code, faster, and cheaper. |
| "Let me skip Phase B since I already shipped" | If the user asked for it, run it. Phase B catches issues Phase A's pre-impl review couldn't see (e.g., the implementation drifted from the plan). |
| "Let me fold the code fixes and the impl-review file edits into one commit" | No. Source fixes get their own conventional commit(s); the impl-review file gets its own `opus: address codex impl-review ...` commit. Reviewers should be able to read each separately. |

## What this skill does NOT do

- Does NOT call codex itself — dispatches the existing `codex` subagent in both phases.
- Does NOT have Codex commit changes (Windows sandbox blocks writes).
- Does NOT replace `superpowers:writing-plans` — it's the codex-augmented variant. Cross-link, don't duplicate.
- Does NOT replace `superpowers:executing-plans` — Phase B reviews the *output* of executing-plans (or hand-written implementation); it doesn't execute the plan itself.
- Does NOT review arbitrary code with no plan. For that, use `superpowers:requesting-code-review`.
- Does NOT open PRs during iteration in either phase — only optionally at convergence of each phase.

## Cross-references

- `superpowers:writing-plans` — upstream pattern for drafting plans. Same template; Phase A adds the review loop on top.
- `superpowers:executing-plans` — runs between Phase A's Step 6 and Phase B's Step 7. After it completes, re-invoke this skill to enter Phase B.
- `superpowers:requesting-code-review` / `superpowers:receiving-code-review` — sibling patterns for code review *without* a finalized plan. Use those when Phase B doesn't apply.
- `~/.claude/agents/codex.md` — the underlying dispatcher.
- `~/.codex/config.toml` — `[profiles.plan-review]` for Phase A (writer-capable, xhigh), `[profiles.review]` for Phase B (read-only, medium).
- `[[feedback_codex_windows_sandbox]]` — the Windows-sandbox constraint that drives the Opus-writes pattern in both phases.
