#!/usr/bin/env bash
# apply-local.sh — install dotfiles on THIS machine from the git repo.
#
# No Mac required. Run on router/nas after fresh ISO install:
#   git clone https://github.com/j4y-w4lk3r/bmcctl.git ~/bmcctl
#   ~/bmcctl/homelab-dotfiles/apply-local.sh
#
# Or if repo already exists:
#   cd ~/bmcctl && git pull && homelab-dotfiles/apply-local.sh
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config-src.sh
source "$DOTFILES_DIR/lib/config-src.sh"
CONFIG_SRC="$(resolve_config_src "$DOTFILES_DIR" "$HOME")"

echo "::: apply-local (config source: $CONFIG_SRC)"

if [[ ! -d "$CONFIG_SRC/yazi" && ! -d "$CONFIG_SRC/btop" ]]; then
  echo "FAIL: no vendored config/ — git pull or clone bmcctl first" >&2
  exit 1
fi

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  bash "$DOTFILES_DIR/install-deps.sh"
else
  echo "::: install-deps skipped (SKIP_DEPS=1)"
fi

install -d "$HOME/.config"/{bbm,btop,fastfetch,fzf,gh,gh-dash,jay/profiles,nvim,op,pikvm,starship,tmux,yazi,zsh}
rsync -a "$CONFIG_SRC/bbm/"              "$HOME/.config/bbm/" 2>/dev/null || install -D "$CONFIG_SRC/bbm/config.toml" "$HOME/.config/bbm/config.toml"
rsync -a "$CONFIG_SRC/btop/"            "$HOME/.config/btop/"
rsync -a "$CONFIG_SRC/fastfetch/"       "$HOME/.config/fastfetch/" 2>/dev/null || install -D "$CONFIG_SRC/fastfetch/config.jsonc" "$HOME/.config/fastfetch/config.jsonc"
rsync -a "$CONFIG_SRC/fzf/"             "$HOME/.config/fzf/" 2>/dev/null || true
rsync -a "$CONFIG_SRC/gh/"              "$HOME/.config/gh/" 2>/dev/null || install -D "$CONFIG_SRC/gh/config.yml" "$HOME/.config/gh/config.yml"
rsync -a "$CONFIG_SRC/gh-dash/"         "$HOME/.config/gh-dash/" 2>/dev/null || true
rsync -a "$CONFIG_SRC/nvim/"            "$HOME/.config/nvim/"
rsync -a "$CONFIG_SRC/op/"              "$HOME/.config/op/"
rsync -a "$CONFIG_SRC/pikvm/"           "$HOME/.config/pikvm/"
rsync -a "$CONFIG_SRC/starship/"        "$HOME/.config/starship/"
rsync -a "$CONFIG_SRC/tmux/"            "$HOME/.config/tmux/"
rsync -a "$CONFIG_SRC/yazi/"            "$HOME/.config/yazi/"
# zsh modules live at config/zsh — NOT under the nested config/.config.
# Resolve canonically so both the flat and legacy layouts work.
ZSH_SRC="$DOTFILES_DIR/config/zsh"
[[ -d "$ZSH_SRC" ]] || ZSH_SRC="$CONFIG_SRC/zsh"
if [[ -d "$ZSH_SRC" ]]; then rsync -a "$ZSH_SRC/" "$HOME/.config/zsh/"; fi
if [[ -d "$CONFIG_SRC/jay/profiles" ]]; then rsync -a "$CONFIG_SRC/jay/profiles/" "$HOME/.config/jay/profiles/"; fi
if [[ -d "$DOTFILES_DIR/jay/profiles" ]]; then rsync -a "$DOTFILES_DIR/jay/profiles/" "$HOME/.config/jay/profiles/"; fi
if [[ -f "$DOTFILES_DIR/zsh/platform.zsh" ]]; then rsync -a "$DOTFILES_DIR/zsh/platform.zsh" "$HOME/.config/zsh/platform.zsh"; fi

mkdir -p "$HOME/.config/rui"
[[ -f "$HOME/.config/rui/.env" ]] || cp "$DOTFILES_DIR/rui/.env.example" "$HOME/.config/rui/.env"

cp "$DOTFILES_DIR/zshrc.linux" "$HOME/.zshrc"
sed -i 's/pbcopy/clipcopy/g; s/pbpaste/clippaste/g' "$HOME/.config/zsh/github.zsh" 2>/dev/null || true

echo "::: smoke test (informational — never fails the apply)"
zsh -lic 'echo shell=$SHELL; command -v starship yazi tmux btop zoxide 2>/dev/null; fastfetch -l none 2>/dev/null | head -5' || true
echo "✓ apply-local done — open a new SSH session or: exec zsh"
