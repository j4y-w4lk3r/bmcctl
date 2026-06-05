#!/usr/bin/env bash
# bootstrap-remote.sh — push dotfiles to router/nas WITHOUT a Mac.
#
# Run from any machine with SSH + git (Arch workstation, laptop, CI):
#   git clone https://github.com/j4y-w4lk3r/bmcctl.git ~/bmcctl   # once
#   cd ~/bmcctl/homelab-dotfiles
#   git pull
#   ./bootstrap-remote.sh router nas
#
# What it does per host:
#   1. git clone/pull bmcctl on the remote (~/bmcctl)
#   2. run apply-local.sh on the remote
#
# Perfect after: ./install-host.sh router  (fresh ISO, empty ~/.config)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
REPO_URL="${BMCCTL_REPO:-https://github.com/j4y-w4lk3r/bmcctl.git}"
SKIP_DEPS="${SKIP_DEPS:-0}"

declare -A HOSTS=(
  [router]=192.168.1.63
  [nas]=192.168.1.64
)

bootstrap_one() {
  local label="$1" ip="$2"
  local target="j4y@${ip}"
  echo ""
  echo "════════════════════════════════════════"
  echo "  ${label} (${ip})"
  echo "════════════════════════════════════════"

  ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$target" "echo ok" >/dev/null \
    || { echo "FAIL: cannot ssh $target"; return 1; }

  ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" -t "$target" bash -s <<REMOTE
set -euo pipefail
if [[ -d ~/bmcctl/.git ]]; then
  echo "::: git pull ~/bmcctl"
  git -C ~/bmcctl pull --ff-only
else
  echo "::: git clone $REPO_URL"
  git clone "$REPO_URL" ~/bmcctl
fi
export SKIP_DEPS=${SKIP_DEPS}
~/bmcctl/homelab-dotfiles/apply-local.sh
REMOTE
  echo "✓ ${label}"
}

[[ $# -ge 1 ]] || { echo "usage: $0 router [nas ...]"; exit 1; }
for label in "$@"; do
  ip="${HOSTS[$label]:-}"
  [[ -n "$ip" ]] || { echo "unknown host: $label"; exit 1; }
  bootstrap_one "$label" "$ip"
done
echo ""
echo "Done."
