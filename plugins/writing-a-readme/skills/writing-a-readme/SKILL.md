---
name: writing-a-readme
description: Use when creating, auditing, reviewing, improving, or rewriting a project's README.md. Triggers on requests like "write a readme", "audit my readme", "improve this readme", or "make this match the forge readme style". Auto-detects greenfield vs. existing README and project type from project-metadata files.
user-invocable: true
argument-hint: [audit|generate]
allowed-tools: Read Write Edit Glob Grep Bash(git *)
---

# Writing a README

## Overview

Generate or audit a project's `README.md` against a fixed structure. Universal core sections always appear; conditional sections only when the project's shape calls for them. Per-section templates and best-practice notes live in `sections.md` next to this file — read it before writing or auditing.

## When to use

- New project without a README, or with a stub <50 lines
- Existing README that should be brought up to a uniform standard across the user's projects
- Direct request: "write/audit/improve/rewrite my readme" or "make my readme like forge"

## Workflow

1. **Detect state.** Default: `README.md` missing or <50 lines → **generate**; otherwise → **audit**. To override, the user passes the bare word `audit` or `generate` as the argument (e.g., `/writing-a-readme audit`).

2. **Detect project type.** Read whichever metadata files exist at the repo root (in this order, then merge). Ignore manifests inside `node_modules/`, `vendor/`, `build/`, `dist/`, `.venv/`, `target/`, `.tox/`, `__pycache__/`, or any path matched by `.gitignore`:
   - `pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `pubspec.yaml`, `composer.json`, `Gemfile`
   - Layout signals: `bin/`, `cmd/`, `src/`, `pkg/`, `apps/`, `services/`, `examples/`, `lib/`
   When more than one root manifest exists (polyglot/monorepo), classify as **monorepo/polyglot**. Otherwise pick one of: **CLI tool**, **library/SDK**, **service/API**, **web app**.

3. **Extract context.** Run in parallel:
   - `git remote get-url origin` (repo URL, owner)
   - `git log --format='%an' | sort -u | head` (contributors)
   - `git tag --list --sort=-v:refname | head` (recent versions)
   - `git rev-list --count HEAD` (commit count, signal of maturity)
   Glob for `Dockerfile`, `docker-compose.yml`, `.github/workflows/`, `tests/`, `examples/`, plugin/extension entry points (`forge.plugins`, `entry_points`, etc.).

4. **Build the section list.** Read `sections.md` — it's the single source of truth for which sections are universal vs. conditional and the `project-type → applicable conditional sections` mapping. Don't restate the section list here; defer to `sections.md` to avoid drift.

5. **Ask focused questions** — only what cannot be inferred. Ask one at a time:
   - One-line tagline
   - Target audience
   - Key differentiators (and which alternatives to name in the intro)
   - "What's new?" content (skip if pre-1.0 with no tagged releases)
   - Stability claim for Project Status (alpha / beta / stable; what's experimental)

6. **Write or audit.**
   - **Generate:** produce a complete draft following `sections.md`, write to `README.md`, then show the user the section list and key facts before they look at the file.
   - **Audit:** compare the existing README section-by-section against the template; flag missing, weak, or out-of-order sections; propose targeted Edit-tool patches per finding. Only rewrite the whole file if the user explicitly asks.

7. **Verify before writing.**
   - Show the chosen section list and the extracted facts (project type, repo URL, version, language, license).
   - Confirm before overwriting an existing README.
   - For audits, show the full diff before applying the Edit patches.

## Key principles

- **Centered header with badges** — version, language, license, platform, CI, PRs welcome, plus per-project metadata badges (test count, plugin count) when they convey real info.
- **Intro paragraph names alternatives + differentiators** in one paragraph (e.g., "where create-next-app gives X, this gives Y"). Hyperlink every named tool on first mention.
- **Quick Start = three commands max**, with no hidden prerequisites; the third must produce visible success (URL, JSON payload, "tests passed").
- **Cite every dependency with a hyperlink the first time it's mentioned** — humans get a click-through, AI agents get the upstream doc URL.
- **Documentation table over long inline reference** — link to `docs/*.md` rather than padding the README.
- **Honest Project Status** at the bottom — alpha/beta/stable, what's experimental, what's tier-1 vs. tier-N if the project has tiers.
- **AI-agent-friendly when applicable** — show stdin/JSON pathway, structured exit codes, machine-readable outputs.
- **Roadmap splits Shipped / Considered / Next-up** when the project is OSS and maintained — makes maturity visible.
- **One-paragraph rule:** every non-table section opens with at most one paragraph of prose before tables/code/lists.

## Reference

Per-section templates, when-to-include rules, principles, and forge-README example pointers: `sections.md` in this skill directory.
