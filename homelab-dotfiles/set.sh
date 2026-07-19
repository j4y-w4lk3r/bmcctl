#!/usr/bin/env bash
# set.sh — one-shot workstation bootstrap (fresh Arch → shell + 1Password + dotfiles)
#
# Run on a new machine (QEMU VM, laptop, etc.):
#   curl -fsSL https://set.d0j0.dev | bash
#
# Or from git:
#   curl -fsSL https://raw.githubusercontent.com/j4y-w4lk3r/bmcctl/main/homelab-dotfiles/set.sh | bash
#
# What you need physically:
#   - network
#   - your 1Password account password (one prompt)
#   - optional: Token2 / YubiKey for later (bio-age, SSH)
#
# No secrets are stored in this script or on set.d0j0.dev.
set -euo pipefail

SET_VERSION='1'
REPO="${BMCCTL_REPO:-https://github.com/j4y-w4lk3r/bmcctl.git}"
DIR="${BMCCTL_DIR:-$HOME/bmcctl}"
OP_ACCOUNT="${OP_ACCOUNT:-my.1password.com}"
export OP_ACCOUNT
export OP_BIOMETRIC_UNLOCK_ENABLED="${OP_BIOMETRIC_UNLOCK_ENABLED:-true}"

say()  { printf '\033[1;35m> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m  %s\n' "$*"; }
die()  { warn "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "Run as your normal user, not root."

say "set.sh v${SET_VERSION} — workstation bootstrap"

# --- 0. preflight -----------------------------------------------------------
command -v pacman >/dev/null || die "Arch Linux (pacman) required."

if ! ping -c1 -W3 1.1.1.1 &>/dev/null && ! ping -c1 -W3 archlinux.org &>/dev/null; then
  die "No network — connect first, then re-run."
fi
ok "network up"

# --- 1. base tools ----------------------------------------------------------
say "Installing base tools (git, curl, sudo, openssh)…"
sudo pacman -S --needed --noconfirm git curl sudo openssh base-devel || true
ok "base tools"

# --- 2. clone / update bmcctl -----------------------------------------------
say "Fetching bmcctl…"
if [[ -d "$DIR/.git" ]]; then
  git -C "$DIR" pull --ff-only
else
  git clone "$REPO" "$DIR"
fi
ok "repo at $DIR"

DOTFILES="$DIR/homelab-dotfiles"
[[ -d "$DOTFILES" ]] || die "missing $DOTFILES"

# --- 3. workstation packages ------------------------------------------------
say "Installing shell + 1Password packages…"
export INSTALL_AUR="${INSTALL_AUR:-1}"
bash "$DOTFILES/install-deps.sh"

# 1Password *desktop* app (needed for op signin / biometric unlock on Linux)
if ! command -v 1password &>/dev/null && ! command -v 1Password &>/dev/null; then
  say "Installing 1Password desktop app (AUR)…"
  if command -v yay >/dev/null; then
    yay -S --needed --noconfirm 1password 2>/dev/null \
      || warn "1password AUR install failed — install manually for biometric unlock"
  else
    warn "install yay, then: yay -S 1password"
  fi
fi

# Optional mesh (skip with SET_SKIP_TAILSCALE=1)
if [[ "${SET_SKIP_TAILSCALE:-0}" != "1" ]] && ! command -v tailscale &>/dev/null; then
  say "Installing tailscale…"
  sudo pacman -S --needed --noconfirm tailscale 2>/dev/null \
    || warn "tailscale not installed — join mesh manually later"
  sudo systemctl enable --now tailscaled 2>/dev/null || true
fi

# Token2 / FIDO stack (skip with SET_SKIP_FIDO=1)
if [[ "${SET_SKIP_FIDO:-0}" != "1" ]]; then
  say "Installing FIDO / age stack…"
  sudo pacman -S --needed --noconfirm pcsclite ccid pcsc-tools libfido2 age 2>/dev/null || true
  sudo systemctl enable --now pcscd 2>/dev/null || true
  if [[ -x "$HOME/token2-setup/token2-linux-setup.sh" ]]; then
    bash "$HOME/token2-setup/token2-linux-setup.sh" 2>/dev/null || true
  elif [[ -x "$DIR/../token2-setup/token2-linux-setup.sh" ]]; then
    bash "$DIR/../token2-setup/token2-linux-setup.sh" 2>/dev/null || true
  fi
fi

# --- 4. dotfiles (configs only — secrets come next) -------------------------
say "Applying dotfiles…"
export SKIP_DEPS=1
bash "$DOTFILES/apply-local.sh"
ok "dotfiles applied"

# --- 5. 1Password unlock (the one human step) --------------------------------
say "1Password sign-in"
warn "Unlock the 1Password app if it is open. Enable:"
warn "  Settings → Developer → Integrate with 1Password CLI"
echo

if ! bash "$DIR/scripts/op-ensure-auth.sh" signin; then
  warn "op signin failed — finish manually:"
  echo "    op signin --account $OP_ACCOUNT"
  echo "  Then run:"
  echo "    $DIR/scripts/homelab-ssh-key.sh ensure"
  echo "    source ~/.zshrc"
  exit 1
fi
eval "$(bash "$DIR/scripts/op-ensure-auth.sh" export)"
ok "1Password session active ($(op whoami 2>/dev/null || echo signed-in))"

# --- 6. pull secrets from 1Password -----------------------------------------
say "Materializing SSH key from 1Password…"
if bash "$DIR/scripts/homelab-ssh-key.sh" ensure 2>/dev/null; then
  ok "homelab SSH key installed"
else
  warn "homelab-ssh-key skipped (op item missing or wrong vault)"
fi

# rclone.conf if documented in 1Password (best-effort)
if command -v op &>/dev/null && op read 'op://Private/rclone/config' &>/dev/null 2>&1; then
  mkdir -p "$HOME/.config/rclone"
  op read 'op://Private/rclone/config' >"$HOME/.config/rclone/rclone.conf"
  chmod 600 "$HOME/.config/rclone/rclone.conf"
  ok "rclone.conf restored from op"
fi

# --- 7. done ----------------------------------------------------------------
echo
say "Bootstrap complete."
echo "  source ~/.zshrc     # load aliases (bae, trustlay, op, …)"
echo "  trustlay flow       # see the trust model"
echo "  bio-age setup       # Token2 age identity (if using Bio key)"
echo "  tailscale up        # join mesh if not already"
echo
ok "simulate on QEMU: re-run this same curl command on the VM"
