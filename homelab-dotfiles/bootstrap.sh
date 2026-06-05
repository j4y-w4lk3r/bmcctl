#!/usr/bin/env bash
# bootstrap.sh — run ON the router/nas itself. No Mac, no rsync from laptop.
#
#   curl -fsSL https://raw.githubusercontent.com/j4y-w4lk3r/bmcctl/main/homelab-dotfiles/bootstrap.sh | bash
#
# Or if you already have the repo:
#   ~/bmcctl/homelab-dotfiles/bootstrap.sh
#
# What it does:
#   1. git clone or git pull github.com/j4y-w4lk3r/bmcctl → ~/bmcctl
#   2. apply-local.sh (pacman deps + copy config/ → ~/.config + ~/.zshrc)
set -euo pipefail

REPO="${BMCCTL_REPO:-https://github.com/j4y-w4lk3r/bmcctl.git}"
DIR="${BMCCTL_DIR:-$HOME/bmcctl}"
SKIP_DEPS="${SKIP_DEPS:-0}"

echo "::: homelab dotfiles bootstrap"
echo "    repo: $REPO"
echo "    dir:  $DIR"

if [[ -d "$DIR/.git" ]]; then
  echo "::: git pull"
  git -C "$DIR" pull --ff-only
else
  echo "::: git clone (one-time, ~20 MB)"
  git clone "$REPO" "$DIR"
fi

export SKIP_DEPS
exec "$DIR/homelab-dotfiles/apply-local.sh"
