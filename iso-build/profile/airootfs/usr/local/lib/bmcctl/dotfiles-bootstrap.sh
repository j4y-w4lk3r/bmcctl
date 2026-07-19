#!/usr/bin/env bash
# First-boot: clone homelab dotfiles from GitHub and apply locally.
# Enabled by install.sh when DOTFILES_BOOTSTRAP=yes in install-config.env.
set -euo pipefail

MARKER=/var/lib/bmcctl/dotfiles-done
[[ -f $MARKER ]] && exit 0

REPO="${DOTFILES_REPO:-https://github.com/j4y-w4lk3r/bmcctl.git}"
DIR="${DOTFILES_DIR:-/home/j4y/bmcctl}"
USER="${DOTFILES_USER:-j4y}"
LOG=/var/log/bmcctl-dotfiles.log

exec >>"$LOG" 2>&1
echo "::: bmcctl dotfiles bootstrap $(date -Is)"

for i in $(seq 1 60); do
  ping -c1 -W2 github.com &>/dev/null && break
  sleep 2
done

if [[ -d $DIR/.git ]]; then
  # Pull AS THE USER (repo is user-owned). Running git as root here trips
  # git's "dubious ownership" guard and aborts the whole bootstrap, which
  # also breaks the retry-on-next-boot path. Never fatal: a failed pull
  # must not stop us from re-applying the dotfiles already on disk.
  sudo -u "$USER" git -C "$DIR" pull --ff-only || echo "WARN: git pull failed; applying existing checkout"
else
  sudo -u "$USER" git clone "$REPO" "$DIR"
fi

if [[ -x $DIR/homelab-dotfiles/apply-local.sh ]]; then
  sudo -u "$USER" SKIP_DEPS=1 "$DIR/homelab-dotfiles/apply-local.sh"
else
  # Fallback for older bmcctl commits (config/.config layout).
  SRC="$DIR/homelab-dotfiles/config/.config"
  [[ -d $SRC/yazi ]] || SRC="$DIR/homelab-dotfiles/config"
  install -d -o "$USER" -g "$USER" "/home/$USER/.config"
  sudo -u "$USER" rsync -a "$SRC/" "/home/$USER/.config/" --exclude rclone
  sudo -u "$USER" rsync -a "$DIR/homelab-dotfiles/config/zsh/" "/home/$USER/.config/zsh/" 2>/dev/null || true
  sudo -u "$USER" rsync -a "$DIR/homelab-dotfiles/jay/profiles/" "/home/$USER/.config/jay/profiles/" 2>/dev/null || true
  install -o "$USER" -g "$USER" -m644 "$DIR/homelab-dotfiles/zshrc.linux" "/home/$USER/.zshrc"
fi

# Make zsh the login shell regardless of which apply path ran above
# (apply-local.sh only lays down config; it does not chsh). Best-effort:
# if zsh isn't installed on this host, leave the shell untouched.
if command -v zsh >/dev/null 2>&1; then
  chsh -s "$(command -v zsh)" "$USER" || true
fi

# Drop bash skel leftovers — homelab is zsh-only.
rm -f "/home/$USER/.bash_logout" \
      "/home/$USER/.bash_profile" \
      "/home/$USER/.bashrc"

mkdir -p /var/lib/bmcctl
touch "$MARKER"
systemctl disable bmcctl-dotfiles.service
echo "::: done"
