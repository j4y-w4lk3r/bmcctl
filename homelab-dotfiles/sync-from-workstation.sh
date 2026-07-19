#!/usr/bin/env bash
# sync-from-workstation.sh — push dotfiles from THIS machine (Arch laptop) to homelab hosts.
# Wrapper around sync.sh; uses vendored homelab-dotfiles/config/ (git) as source of truth.
#
# Usage:
#   ./sync-from-workstation.sh nas
#   NAS_IP=192.168.1.65 ./sync-from-workstation.sh nas
#   DRY_RUN=1 ./sync-from-workstation.sh nas router
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
[[ -f $SSH_KEY ]] || {
  echo "missing SSH key $SSH_KEY — run: homelab-ssh-key ensure" >&2
  exit 1
}
exec "$DIR/sync.sh" "$@"
