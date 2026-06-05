#!/usr/bin/env bash
# vendor-from-mac.sh — snapshot Mac dotfiles into this repo for GitHub.
#
# Run once (or whenever you change configs on the Mac), then commit + push:
#   ./vendor-from-mac.sh
#   git add homelab-dotfiles/config homelab-dotfiles/zshrc.mac
#   git commit -m "dotfiles: sync from Mac"
#   git push
#
# Secrets are excluded (see .gitignore). After a Mac reset:
#   git clone …/bmcctl && cd bmcctl/homelab-dotfiles
#   ./restore-to-mac.sh          # repopulate ~/.config on the Mac
#   SKIP_DEPS=1 ./sync.sh router nas
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_HOME="${MAC_HOME:-$HOME}"
CONFIG_DIR="$DOTFILES_DIR/config"

echo "::: vendoring Mac configs → $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

copy_path() {
  local src="$MAC_HOME/$1" dst="$CONFIG_DIR/$1"
  [[ -e "$src" ]] || { echo "  skip (missing): $1"; return 0; }
  mkdir -p "$(dirname "$dst")"
  rsync -a --delete \
    --exclude '.git' --exclude '.DS_Store' \
    "$src" "$(dirname "$dst")/"
  echo "  ✓ $1"
}

# ~/.config trees (user-requested)
copy_path ".config/bbm/config.toml"
copy_path ".config/btop"
copy_path ".config/fastfetch/config.jsonc"
copy_path ".config/fzf/zsh-keybindings.zsh"
copy_path ".config/gh/config.yml"
copy_path ".config/gh-dash/config.yml"
copy_path ".config/jay/profiles"
copy_path ".config/jay/README.md"
copy_path ".config/nvim"
copy_path ".config/op"
copy_path ".config/pikvm"
copy_path ".config/rclone"          # rclone.conf excluded via .gitignore
copy_path ".config/starship"
copy_path ".config/tmux"
copy_path ".config/yazi"

# zsh modules
mkdir -p "$CONFIG_DIR/zsh"
for f in jay.zsh github.zsh git-account.zsh backblaze.zsh imgconv.zsh imgconv.zsh brew.zsh; do
  [[ -f "$MAC_HOME/.config/zsh/$f" ]] && cp "$MAC_HOME/.config/zsh/$f" "$CONFIG_DIR/zsh/$f" && echo "  ✓ .config/zsh/$f"
done
[[ -f "$DOTFILES_DIR/zsh/platform.zsh" ]] && cp "$DOTFILES_DIR/zsh/platform.zsh" "$CONFIG_DIR/zsh/platform.zsh"

# Mac .zshrc (full version — Linux uses zshrc.linux)
cp "$MAC_HOME/.zshrc" "$DOTFILES_DIR/zshrc.mac"
echo "  ✓ zshrc.mac"

# Secret templates only (never copy live credentials into git)
mkdir -p "$CONFIG_DIR/rui"
cp "$DOTFILES_DIR/rui/.env.example" "$CONFIG_DIR/rui/.env.example"
echo "  ✓ rui/.env.example (template — fill secrets via 1Password after Mac reset)"

echo ""
echo "Done. Review with:  git status homelab-dotfiles/"
echo "Then:  git add homelab-dotfiles/ && git commit && git push"
