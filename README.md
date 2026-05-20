# cchifor/claude

My personal Claude Code setup, shareable across machines. A small plugin
marketplace plus the dotfiles I want in `~/.claude` on every box I touch.

## What's in here

```
.claude-plugin/marketplace.json   marketplace manifest (3 plugins)
plugins/
  codex-toolkit/                  codex dispatcher subagent + plan-review skill
  forge/                          forge CLI scaffolding skill
  writing-a-readme/               README generator/auditor skill
dotfiles/
  CLAUDE.md                       user-scope preferences (commit style, etc.)
  settings.json                   base settings (permissions, plugins, defaults)
SETUP.md                          agent-executable setup playbook
```

## Plugins

| Plugin | What it does |
|---|---|
| **codex-toolkit** | Dispatches OpenAI Codex CLI as a Claude Code subagent and drives an Opus<->Codex feedback loop for plan review. Bundles the `codex` subagent and the `codex-reviewed-planning` skill. Windows-tuned (cmd /c stdin handling, read-only sandbox workarounds for codex v0.130). |
| **forge** | Generates full-stack projects via the `forge` CLI in headless mode. Python/FastAPI, Node/Fastify, Rust/Axum backends; Vue/Svelte/Flutter frontends. Requires the `forge` CLI installed separately. |
| **writing-a-readme** | Generates or audits a project's `README.md` against a fixed structure. Auto-detects project type from manifest files. |

## Setting up a new machine

### Recommended: let Claude do it

Open Claude Code on the new machine and paste this prompt:

> Clone `https://github.com/cchifor/claude`, read `SETUP.md` from the
> repo, and execute every step. Tell me which slash commands to run
> when you're done.

Claude will detect your OS (Windows or Unix), clone the repo, back up
any existing `~/.claude/CLAUDE.md` and `settings.json`, copy the
dotfiles in, and print the slash commands you need to type to install
the plugins.

### Manual setup

`SETUP.md` is human-readable too — open it and run each step's
Windows or Unix variant by hand. The slash commands at the end are
the same either way.

## What this repo deliberately does **not** sync

- **Auto-memory** (`~/.claude/projects/<encoded-cwd>/memory/`) — the
  directory name encodes the absolute working directory, which differs
  per machine. Anything from auto-memory that is genuinely cross-machine
  has been promoted into `dotfiles/CLAUDE.md`.
- **`settings.local.json`**, machine-specific Bash allowlists, hooks
  referencing local paths, anything with secrets.
- **Per-project `.claude/`** directories — those belong in each
  project's own repo.

## Updating after changes

After `git pull` in your local clone, re-run the setup prompt above
(or step 4 of `SETUP.md` by hand) to copy the new dotfiles in.
Plugins update via:

```
/plugin marketplace update chifor-claude
```
