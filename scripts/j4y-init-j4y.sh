#!/usr/bin/env bash
# init-j4y.sh — bootstrap j4y profile from USB or local bmcctl
#
# Usage:
#   bash init-j4y.sh              # from USB bootstrap/
#   bash init-j4y.sh --offline    # skip network pulls
set -euo pipefail

OFFLINE=0
[[ "${1:-}" == --offline ]] && OFFLINE=1

USB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say()  { printf '\033[1;35m> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m  %s\n' "$*"; }

say "j4y profile init (offline=${OFFLINE})"

if [[ -f "$USB_ROOT/bootstrap/packages.txt" ]]; then
  say "Installing base packages…"
  sudo pacman -S --needed --noconfirm \
    git curl openssh sudo base-devel \
    pcsclite ccid pcsc-tools libfido2 \
    age gnupg pinentry openpgp-card-tools 2>/dev/null || true
  ok "packages"
fi

mkdir -p "$HOME/.config/persona"
if [[ ! -f "$HOME/.config/persona/j4y.env" ]] && [[ -f "$USB_ROOT/public/persona/j4y.env.example" ]]; then
  cp "$USB_ROOT/public/persona/j4y.env.example" "$HOME/.config/persona/j4y.env"
  ok "persona env → ~/.config/persona/j4y.env"
fi

# shellcheck disable=SC1091
[[ -f "$HOME/.config/persona/j4y.env" ]] && source "$HOME/.config/persona/j4y.env"

if [[ "$OFFLINE" == 0 ]] && ping -c1 -W2 1.1.1.1 &>/dev/null; then
  if [[ -x "$HOME/token2-setup/token2-linux-setup.sh" ]]; then
    say "Token2 setup…"
    bash "$HOME/token2-setup/token2-linux-setup.sh" || warn "token2 setup skipped"
  fi
  if [[ -f "$USB_ROOT/bootstrap/set.sh" ]]; then
    warn "Network available — consider: curl -fsSL ${SET_URL:-https://set.d0j0.dev} | bash"
  fi
else
  warn "Offline mode — run token2-linux-setup and set.sh when online"
fi

if command -v token2 &>/dev/null; then
  token2 doctor 2>/dev/null || true
fi

echo
say "Next steps"
echo "  1. ceremony/checklist.md  (if keys not configured yet)"
echo "  2. trustlay personas"
echo "  3. Vaultwarden login when vw.d0j0.dev is live"
echo "  4. op signin (Layer 2 bootstrap only)"
ok "j4y init pass complete"
