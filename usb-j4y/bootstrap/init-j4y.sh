#!/usr/bin/env bash
# init-j4y.sh — bootstrap j4y profile from J4Y-ROOT USB
set -euo pipefail

OFFLINE=0
[[ "${1:-}" == --offline ]] && OFFLINE=1

USB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/j4y-lib.sh
source "$USB_ROOT/bootstrap/lib/j4y-lib.sh"

say()  { j4y_say "$*"; }
ok()   { j4y_ok "$*"; }
warn() { j4y_warn "$*"; }

say "j4y init (offline=$([[ $OFFLINE -eq 1 ]] && echo 1 || echo 0))"

if command -v pacman &>/dev/null && [[ -f "$USB_ROOT/bootstrap/packages.txt" ]]; then
  say "Installing packages (Arch)…"
  sudo pacman -S --needed --noconfirm \
    git curl openssh sudo base-devel python \
    pcsclite ccid pcsc-tools libfido2 \
    age gnupg pinentry openpgp-card-tools 2>/dev/null || true
  ok "packages"
elif ! command -v pacman &>/dev/null; then
  warn "Not Arch/pacman — install packages manually (see bootstrap/packages.txt)"
fi

mkdir -p "$HOME/.config/persona"
if [[ ! -f "$HOME/.config/persona/j4y.env" ]] && [[ -f "$USB_ROOT/public/persona/j4y.env.example" ]]; then
  cp "$USB_ROOT/public/persona/j4y.env.example" "$HOME/.config/persona/j4y.env"
  ok "persona → ~/.config/persona/j4y.env"
fi

# shellcheck disable=SC1091
[[ -f "$HOME/.config/persona/j4y.env" ]] && source "$HOME/.config/persona/j4y.env"

if [[ "$OFFLINE" == 0 ]] && ping -c1 -W2 1.1.1.1 &>/dev/null; then
  [[ -x "$HOME/token2-setup/token2-linux-setup.sh" ]] && bash "$HOME/token2-setup/token2-linux-setup.sh" || true
  warn "Online: curl -fsSL ${SET_URL:-https://set.d0j0.dev} | bash"
else
  warn "Offline — run ./run init when ready; set.d0j0.dev when online"
fi

command -v token2 &>/dev/null && token2 doctor 2>/dev/null || true

echo
say "Next: ./run ceremony   then trustlay personas"
ok "init complete"
