#!/usr/bin/env bash
# Bootstrap a new Linux/macOS machine with my Claude Code setup.
#
# What this does:
#   1. Symlinks dotfiles/CLAUDE.md      -> ~/.claude/CLAUDE.md
#   2. Symlinks dotfiles/settings.json  -> ~/.claude/settings.json
#      (existing files are backed up to ~/.claude/<name>.bak.<timestamp>)
#   3. Prints the slash commands to run inside Claude Code.
#
# Run from the root of a fresh clone of https://github.com/cchifor/claude:
#   ./bootstrap/bootstrap.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dotfiles="${repo_root}/dotfiles"
claude_home="${HOME}/.claude"

mkdir -p "${claude_home}"

link_dotfile() {
    local src="$1"
    local target="$2"

    if [[ -e "${target}" || -L "${target}" ]]; then
        local stamp backup
        stamp="$(date +%Y%m%d-%H%M%S)"
        backup="${target}.bak.${stamp}"
        echo "Backing up ${target} -> ${backup}"
        mv "${target}" "${backup}"
    fi

    echo "Linking ${target} -> ${src}"
    ln -s "${src}" "${target}"
}

link_dotfile "${dotfiles}/CLAUDE.md"     "${claude_home}/CLAUDE.md"
link_dotfile "${dotfiles}/settings.json" "${claude_home}/settings.json"

cat <<'EOF'

Dotfiles linked. Now open Claude Code and run:

  /plugin marketplace add cchifor/claude
  /plugin install codex-toolkit@chifor-claude
  /plugin install forge@chifor-claude
  /plugin install writing-a-readme@chifor-claude

If you use the codex-toolkit plugin, also install the codex CLI:
  npm install -g @openai/codex
and configure ~/.codex/config.toml with your profiles.
EOF
