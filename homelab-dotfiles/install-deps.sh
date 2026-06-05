#!/usr/bin/env bash
# install-deps.sh — Arch packages for the homelab shell experience.
# Run on router/nas (idempotent). Called by sync.sh or standalone.
set -uo pipefail

echo "::: pacman (official repos)"
# Do NOT pipe through tail — that hides all output until pacman exits and
# looks like a silent hang over SSH.  set -e is off so one missing optional
# package does not abort the whole script.
sudo pacman -S --needed --noconfirm \
  zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting \
  fzf bat eza starship fastfetch btop yazi tmux github-cli lazygit \
  ripgrep fd zoxide jq man-db man-pages wget unzip zip p7zip \
  xclip wl-clipboard \
  nvim helix git-delta \
  || echo "::: pacman: some packages missing (non-fatal)"

# 1Password CLI — package name varies; try both.
sudo pacman -S --needed --noconfirm 1password 2>/dev/null \
  || yay -S --needed --noconfirm 1password-cli 2>/dev/null \
  || echo "::: op CLI not installed — install 1password or 1password-cli manually"

# AUR helpers — opt-in (AUR builds can take 10+ min on first install).
# Re-run with:  INSTALL_AUR=1 bash install-deps.sh
if [[ "${INSTALL_AUR:-0}" == "1" ]] && command -v yay >/dev/null 2>&1; then
  echo "::: AUR (yay) — INSTALL_AUR=1"
  yay -S --needed --noconfirm \
    forgit zsh-vi-mode rui-bin gh-dash-bin 2>&1 | tail -8 || \
    echo "::: (some AUR packages skipped — install manually if needed)"
else
  echo "::: skipping AUR (set INSTALL_AUR=1 to install forgit/zsh-vi-mode/rui-bin/gh-dash)"
fi

# Default shell → zsh (only changes if not already zsh)
if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "/bin/zsh" ]]; then
  echo "::: chsh → zsh"
  sudo chsh -s /bin/zsh "$USER"
fi

echo "::: done"
