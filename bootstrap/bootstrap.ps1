# Bootstrap a new Windows machine with my Claude Code setup.
#
# What this does:
#   1. Symlinks dotfiles/CLAUDE.md      -> ~/.claude/CLAUDE.md
#   2. Symlinks dotfiles/settings.json  -> ~/.claude/settings.json
#      (existing files are backed up to ~/.claude/<name>.bak.<timestamp>)
#   3. Prints the slash commands to run inside Claude Code to add the
#      marketplace and install the three plugins.
#
# Run from the root of a fresh clone of https://github.com/cchifor/claude:
#   pwsh ./bootstrap/bootstrap.ps1
#
# Requires an elevated shell or Developer Mode enabled for symlinks.

$ErrorActionPreference = "Stop"

$repoRoot   = Split-Path -Parent $PSScriptRoot
$dotfiles   = Join-Path $repoRoot "dotfiles"
$claudeHome = Join-Path $HOME ".claude"

if (-not (Test-Path $claudeHome)) {
    New-Item -ItemType Directory -Path $claudeHome | Out-Null
}

function Link-Dotfile {
    param([string]$Source, [string]$Target)

    if (Test-Path $Target) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backup = "$Target.bak.$stamp"
        Write-Host "Backing up $Target -> $backup"
        Move-Item -Path $Target -Destination $backup
    }

    Write-Host "Linking $Target -> $Source"
    New-Item -ItemType SymbolicLink -Path $Target -Target $Source | Out-Null
}

Link-Dotfile -Source (Join-Path $dotfiles "CLAUDE.md")     -Target (Join-Path $claudeHome "CLAUDE.md")
Link-Dotfile -Source (Join-Path $dotfiles "settings.json") -Target (Join-Path $claudeHome "settings.json")

Write-Host ""
Write-Host "Dotfiles linked. Now open Claude Code and run:"
Write-Host ""
Write-Host "  /plugin marketplace add cchifor/claude"
Write-Host "  /plugin install codex-toolkit@chifor-claude"
Write-Host "  /plugin install forge@chifor-claude"
Write-Host "  /plugin install writing-a-readme@chifor-claude"
Write-Host ""
Write-Host "If you use the codex-toolkit plugin, also install the codex CLI:"
Write-Host "  npm install -g @openai/codex"
Write-Host "and configure ~/.codex/config.toml with your profiles."
