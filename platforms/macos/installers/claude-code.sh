#!/usr/bin/env bash
# Claude Code installer: status | install | update | reinstall | uninstall
# Anthropic's native installer puts the CLI in ~/.local/bin and keeps it updated
# itself. Uninstall leaves ~/.claude (settings, sessions) alone.

set -euo pipefail

CLI="$HOME/.local/bin/claude"
DATA="$HOME/.local/share/claude"

case "${1:-status}" in
    status)
        [[ -x "$CLI" ]] || exit 1
        printf '%s\n' "$CLI"
        ;;
    install|reinstall)
        curl -fsSL https://claude.ai/install.sh | bash
        ;;
    update)
        "$CLI" update
        ;;
    uninstall)
        [[ -e "$CLI" ]] || { echo "Claude Code is not installed."; exit 1; }
        rm -rf "$CLI" "$DATA"
        echo "Removed $CLI and $DATA"
        ;;
    *)
        echo "usage: $(basename "$0") <status|install|update|reinstall|uninstall>" >&2
        exit 2
        ;;
esac
