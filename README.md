# cchifor/claude

My personal Claude Code setup, shareable across machines. A small plugin
marketplace plus the dotfiles I want symlinked into `~/.claude` on every
box I touch.

## What's in here

```
.claude-plugin/marketplace.json   # marketplace manifest (3 plugins)
plugins/
  codex-toolkit/                   # codex dispatcher subagent + plan-review skill
  forge/                           # forge CLI scaffolding skill
  writing-a-readme/                # README generator/auditor skill
dotfiles/
  CLAUDE.md                        # user-scope preferences (commit style, etc.)
  settings.json                    # base settings: permissions, plugins, defaults
bootstrap/
  bootstrap.ps1                    # Windows installer
  bootstrap.sh                     # Linux / macOS installer
```

## Plugins

| Plugin | What it does |
|---|---|
| **codex-toolkit** | Dispatches OpenAI Codex CLI as a Claude Code subagent and drives an Opus<->Codex feedback loop for plan review. Bundles the `codex` subagent and the `codex-reviewed-planning` skill. **Windows-tuned** (`cmd /c < NUL` stdin handling, read-only sandbox workarounds for codex v0.130). |
| **forge** | Generates full-stack projects via the `forge` CLI in headless mode. Python/FastAPI, Node/Fastify, Rust/Axum backends; Vue/Svelte/Flutter frontends. Requires the `forge` CLI installed separately. |
| **writing-a-readme** | Generates or audits a project's `README.md` against a fixed structure. Auto-detects project type from manifest files. |

## Setting up a new machine

### 1. Clone this repo somewhere stable

```powershell
# pick a directory you won't move — the bootstrap script creates symlinks
# that point at this clone
git clone https://github.com/cchifor/claude.git ~/work/claude
```

### 2. Symlink the dotfiles

**Windows** (PowerShell, elevated or with Developer Mode enabled):
```powershell
pwsh ~/work/claude/bootstrap/bootstrap.ps1
```

**Linux / macOS**:
```bash
~/work/claude/bootstrap/bootstrap.sh
```

The script backs up any existing `~/.claude/CLAUDE.md` and
`~/.claude/settings.json` to `*.bak.<timestamp>` before linking.

### 3. Install the plugins inside Claude Code

```
/plugin marketplace add cchifor/claude
/plugin install codex-toolkit@chifor-claude
/plugin install forge@chifor-claude
/plugin install writing-a-readme@chifor-claude
```

### 4. (codex-toolkit only) Install the codex CLI

```bash
npm install -g @openai/codex
```

Then create `~/.codex/config.toml` with at least the three profiles the
dispatcher expects: default (writer), `[profiles.review]` (read-only), and
`[profiles.plan-review]` (writer-capable). See
`plugins/codex-toolkit/agents/codex.md` for the exact shape.

## What this repo deliberately does **not** sync

- **Auto-memory** (`~/.claude/projects/<encoded-cwd>/memory/`) — the
  directory name encodes the absolute working directory, which differs per
  machine. Anything from auto-memory that's actually cross-machine has been
  promoted into `dotfiles/CLAUDE.md`.
- **`settings.local.json`**, machine-specific Bash allowlists, hooks
  referencing local paths, anything with secrets.
- **Per-project `.claude/`** directories — those belong in each project's
  own repo.

## Updating after changes

Pull the latest into your local clone and the symlinks pick it up
automatically. Plugins need an explicit refresh:

```
/plugin marketplace update chifor-claude
```
