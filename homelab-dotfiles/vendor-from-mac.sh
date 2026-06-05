#!/usr/bin/env bash
# vendor-from-mac.sh — snapshot Mac dotfiles into this repo for GitHub.
#
# Run once (or whenever you change configs on the Mac), then commit + push:
#   ./vendor-from-mac.sh
#   git add homelab-dotfiles/config homelab-dotfiles/zshrc.mac
#   git commit -m "dotfiles: sync from Mac"
#   git push
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_HOME="${MAC_HOME:-$HOME}"
CONFIG_DIR="$DOTFILES_DIR/config"

echo "::: vendoring Mac configs → $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# Copy $MAC_HOME/.config/<rel> → $CONFIG_DIR/<rel>  (no double .config/)
copy_config() {
  local rel="$1"
  local src="$MAC_HOME/.config/$rel"
  local dst="$CONFIG_DIR/$rel"
  [[ -e "$src" ]] || { echo "  skip (missing): .config/$rel"; return 0; }
  mkdir -p "$(dirname "$dst")"
  if [[ -d "$src" ]]; then
    rsync -a --delete --exclude '.git' --exclude '.DS_Store' "$src/" "$dst/"
  else
    cp "$src" "$dst"
  fi
  echo "  ✓ .config/$rel"
}

copy_config "bbm/config.toml"
copy_config "btop"
copy_config "fastfetch/config.jsonc"
copy_config "fzf/zsh-keybindings.zsh"
copy_config "gh/config.yml"
copy_config "gh-dash/config.yml"
copy_config "jay/profiles"
copy_config "jay/README.md"
copy_config "nvim"
copy_config "op"
copy_config "pikvm"
copy_config "starship"
copy_config "tmux"
copy_config "yazi"
# rclone.conf is gitignored — directory may exist locally but secret file won't commit

mkdir -p "$CONFIG_DIR/zsh"
for f in jay.zsh github.zsh git-account.zsh backblaze.zsh imgconv.zsh brew.zsh; do
  [[ -f "$MAC_HOME/.config/zsh/$f" ]] && cp "$MAC_HOME/.config/zsh/$f" "$CONFIG_DIR/zsh/$f" && echo "  ✓ .config/zsh/$f"
done
cp "$DOTFILES_DIR/zsh/platform.zsh" "$CONFIG_DIR/zsh/platform.zsh"

cp "$MAC_HOME/.zshrc" "$DOTFILES_DIR/zshrc.mac"
echo "  ✓ zshrc.mac"

mkdir -p "$CONFIG_DIR/rui"
cp "$DOTFILES_DIR/rui/.env.example" "$CONFIG_DIR/rui/.env.example"
echo "  ✓ rui/.env.example"

# Clean up legacy double-.config layout from an earlier vendor run.
rm -rf "$CONFIG_DIR/.config"

echo ""
echo "Done. Review:  git status homelab-dotfiles/config/"
