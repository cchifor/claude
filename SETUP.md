# SETUP — agent playbook

You are Claude Code and the user has asked you to set up the
`cchifor/claude` configuration on this machine. Follow these steps in
order. Do **not** skip the verification step at the end.

This file is also human-readable — a person can copy the commands by hand
if they prefer.

---

## Step 0 — Detect the OS

Run the right probe for your current shell:

- **PowerShell** (Windows or pwsh on Linux/macOS):
  ```powershell
  if ($IsWindows -or $env:OS -eq "Windows_NT") { "windows" } else { "unix" }
  ```
- **Bash / sh** (Linux, macOS, Git Bash on Windows):
  ```bash
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo windows ;; *) echo unix ;; esac
  ```

Remember the result. Every subsequent step has a Windows and a Unix
variant — pick the matching one.

## Step 1 — Locate or clone the repo

The repo lives at `https://github.com/cchifor/claude`. If it's already
cloned somewhere on disk, **use that**. Otherwise clone it. Default
location: `$HOME/work/claude`. Ask the user before picking a different
path if their layout is unusual.

- **Windows (PowerShell):**
  ```powershell
  $repo = "$HOME\work\claude"
  if (-not (Test-Path $repo)) {
      New-Item -ItemType Directory -Path (Split-Path $repo -Parent) -Force | Out-Null
      git clone https://github.com/cchifor/claude.git $repo
  } else {
      git -C $repo pull --ff-only
  }
  ```
- **Unix (bash):**
  ```bash
  repo="$HOME/work/claude"
  if [ ! -d "$repo" ]; then
      mkdir -p "$(dirname "$repo")"
      git clone https://github.com/cchifor/claude.git "$repo"
  else
      git -C "$repo" pull --ff-only
  fi
  ```

Set `$repo` (or `$repo` env var on Unix) — every later step uses it.

## Step 2 — Ensure `~/.claude` exists

- **Windows:**
  ```powershell
  $claudeHome = "$HOME\.claude"
  if (-not (Test-Path $claudeHome)) { New-Item -ItemType Directory -Path $claudeHome | Out-Null }
  ```
- **Unix:**
  ```bash
  claude_home="$HOME/.claude"
  mkdir -p "$claude_home"
  ```

## Step 3 — Back up existing dotfiles

For each of `CLAUDE.md` and `settings.json` already in `~/.claude`, move
it aside with a timestamp suffix. This is non-destructive.

- **Windows:**
  ```powershell
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  foreach ($name in @("CLAUDE.md", "settings.json")) {
      $path = Join-Path $claudeHome $name
      if (Test-Path $path) {
          $backup = "$path.bak.$stamp"
          Write-Host "Backing up $path -> $backup"
          Move-Item $path $backup
      }
  }
  ```
- **Unix:**
  ```bash
  stamp="$(date +%Y%m%d-%H%M%S)"
  for name in CLAUDE.md settings.json; do
      path="${claude_home}/${name}"
      if [ -e "${path}" ] || [ -L "${path}" ]; then
          backup="${path}.bak.${stamp}"
          echo "Backing up ${path} -> ${backup}"
          mv "${path}" "${backup}"
      fi
  done
  ```

## Step 4 — Install the dotfiles

**Copy** the files (don't symlink). Copy works everywhere with no admin
privilege or Developer Mode requirement. The trade-off: updates require
re-running this playbook after a `git pull`.

- **Windows:**
  ```powershell
  Copy-Item "$repo\dotfiles\CLAUDE.md"     "$claudeHome\CLAUDE.md"
  Copy-Item "$repo\dotfiles\settings.json" "$claudeHome\settings.json"
  ```
- **Unix:**
  ```bash
  cp "${repo}/dotfiles/CLAUDE.md"     "${claude_home}/CLAUDE.md"
  cp "${repo}/dotfiles/settings.json" "${claude_home}/settings.json"
  ```

## Step 5 — Verify the dotfiles landed

- **Windows:**
  ```powershell
  Get-Item "$claudeHome\CLAUDE.md", "$claudeHome\settings.json" |
      Select-Object FullName, Length, LastWriteTime
  ```
- **Unix:**
  ```bash
  ls -l "${claude_home}/CLAUDE.md" "${claude_home}/settings.json"
  ```

Both files must exist and be non-empty. If anything is missing, stop and
ask the user.

## Step 6 — Tell the user the slash commands to run

You **cannot** invoke Claude Code slash commands from a tool call —
they must be typed by the user. Print this block verbatim and tell them
to paste it into the prompt one line at a time:

```
/plugin marketplace add cchifor/claude
/plugin install codex-toolkit@chifor-claude
/plugin install forge@chifor-claude
/plugin install writing-a-readme@chifor-claude
```

After they run those, Claude Code will pick up the plugins on the next
session start (or sooner — check `/plugin` to confirm).

## Step 7 — Optional: codex CLI

The `codex-toolkit` plugin dispatches OpenAI's Codex CLI. If the user
wants to use it, the CLI must be installed and configured separately:

```
npm install -g @openai/codex
```

Then they need `~/.codex/config.toml` with three profiles: default
(writer), `[profiles.review]` (read-only), and `[profiles.plan-review]`
(writer-capable). The expected shape is documented in
`plugins/codex-toolkit/agents/codex.md`. Offer to scaffold the config
file if they ask.

## Step 8 — Summary

Report back to the user:
- Repo path (where you cloned or found the clone)
- What was backed up (if anything)
- What was copied
- The four slash commands they need to run
- Whether codex CLI setup is pending

Done.
