#!/usr/bin/env bash
# restore-to-mac.sh — after a Mac reset, repopulate ~/.config from the git repo.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$DOTFILES_DIR/config"
MAC_HOME="${MAC_HOME:-$HOME}"

[[ -d "$CONFIG_DIR" ]] || { echo "no config/ — run ./vendor-from-mac.sh first"; exit 1; }

echo "::: restoring $CONFIG_DIR → $MAC_HOME"
rsync -av "$CONFIG_DIR/" "$MAC_HOME/.config/"
cp "$DOTFILES_DIR/zshrc.mac" "$MAC_HOME/.zshrc"
echo "✓ done. Open a new terminal or: source ~/.zshrc"
