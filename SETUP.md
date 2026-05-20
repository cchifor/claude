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

## Step 0.5 — Ensure GitHub auth (one-time per machine)

Claude needs to talk to GitHub for everything from cloning private repos
to opening PRs. This step sets up `gh` CLI auth + an SSH key in one
interactive command. **Skip if `gh auth status` already returns 0.**

### Probe — is `gh` installed and authed?

- **Windows:**
  ```powershell
  try { gh auth status 2>&1 | Out-Null; $authed = $? } catch { $authed = $false }
  ```
- **Unix:**
  ```bash
  if gh auth status >/dev/null 2>&1; then authed=1; else authed=0; fi
  ```

If `$authed` is true → skip the rest of this step. If `gh` isn't installed
or returns non-zero, continue.

### Install `gh` if missing

- **Windows:** `winget install --id GitHub.cli` (or `scoop install gh` / `choco install gh`).
- **macOS:** `brew install gh`.
- **Linux:** follow the official instructions at
  https://github.com/cli/cli/blob/trunk/docs/install_linux.md (one-line
  curl differs by distro). Once installed, `gh --version` should return.

### Run the interactive login

Both shells run the same command — `gh` is cross-platform:

```
gh auth login --git-protocol ssh --web
```

This is a 6-prompt flow. Walk the user through it (the agent cannot
answer for them — the browser auth is intentionally human-driven):

1. **What account?** → `GitHub.com`
2. **What protocol?** → `SSH` (pre-selected by the flag)
3. **Generate a new SSH key?** → `Yes`
4. **Passphrase?** → Enter (empty) for non-interactive use, or pick one
   if the machine isn't trusted to be solo-user.
5. **Title for the SSH key?** → use the machine hostname so each
   machine's key is identifiable in GitHub settings (`hostname` on Unix,
   `$env:COMPUTERNAME` on Windows).
6. **How to authenticate?** → `Login with a web browser` → copy the
   one-time code, hit Enter, paste the code in the browser, authorize.

### Verify

After the login returns:

- **Windows:**
  ```powershell
  gh auth status
  ssh -T git@github.com   # expect: "Hi <username>! You've successfully authenticated..."
  ```
- **Unix:**
  ```bash
  gh auth status
  ssh -T git@github.com -o StrictHostKeyChecking=accept-new
  ```

`ssh -T` is expected to exit with code 1 (GitHub doesn't allow shell
access) — the success signal is the `Hi <username>!` message in stdout,
not the exit code.

### What this leaves on disk

- A new ed25519 key pair at `~/.ssh/id_ed25519` (and `.pub`).
- An entry in `~/.ssh/config` (or `~/.gitconfig`) wiring SSH to github.com.
- A `gh` auth token in the OS credential store (Windows Credential
  Manager / macOS Keychain / Linux keyring).
- A new public key registered against your GitHub account under the
  hostname you picked in prompt 5.

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
/plugin install superpowers@claude-plugins-official
```

After they run those, Claude Code will pick up the plugins on the next
session start (or sooner — check `/plugin` to confirm).

**About the `superpowers` line.** It comes from a different marketplace —
`claude-plugins-official`, which is Anthropic's default marketplace and
ships pre-registered with Claude Code, so no `/plugin marketplace add` is
needed for it. The dotfiles in this repo expect it to be installed:
`dotfiles/settings.json` enables it under `enabledPlugins`, and the
project-level `CLAUDE.md` references brainstorming / debugging / TDD
skills that come from this plugin. If you skip it, those skills won't be
available and you'll see "skill not found" if anything tries to invoke
them.

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
