#!/usr/bin/env bash
# sync.sh — push macOS dotfiles + homelab overlays to router/nas.
#
# Usage:
#   ./sync.sh router nas          # both hosts
#   ./sync.sh router              # router only
#   DRY_RUN=1 ./sync.sh nas       # show what would happen
#
# Prerequisites:
#   - SSH key access as j4y@<host>
#   - Run from your Mac (reads ~/.config/... as source of truth)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_HOME="${MAC_HOME:-$HOME}"
# shellcheck source=lib/config-src.sh
source "$DOTFILES_DIR/lib/config-src.sh"
CONFIG_SRC="$(resolve_config_src "$DOTFILES_DIR" "$MAC_HOME")"
if [[ "$CONFIG_SRC" == "$MAC_HOME/.config" ]]; then
  echo "note: config/ not vendored — reading from Mac ~/.config"
  CONFIG_SRC_IS_MAC=1
else
  CONFIG_SRC_IS_MAC=0
  echo "note: config source = $CONFIG_SRC (from git)"
fi
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
DRY_RUN="${DRY_RUN:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"

declare -A HOSTS=(
  [router]=192.168.1.63
  [nas]=192.168.1.64
)

rsync_to() {
  local dest_user_host="$1" src="$2" remote_path="$3"
  local -a opts=(-az --info=progress2 --delete-excluded --exclude '.git' --exclude '.DS_Store')
  [[ -d "$src" || -f "$src" ]] || { echo "  skip (missing locally): $src"; return 0; }
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  rsync $src → ${dest_user_host}:${remote_path}"
    return 0
  fi
  rsync "${opts[@]}" -e "ssh -i $SSH_KEY ${SSH_OPTS[*]}" \
    "$src" "${dest_user_host}:${remote_path}"
}

deploy_host() {
  local label="$1" ip="$2"
  local target="j4y@${ip}"
  echo ""
  echo "════════════════════════════════════════"
  echo "  ${label} (${ip})"
  echo "════════════════════════════════════════"

  if [[ "$DRY_RUN" != "1" ]]; then
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$target" 'echo ok' >/dev/null \
      || { echo "FAIL: cannot ssh to $target"; return 1; }
    if [[ "$SKIP_DEPS" != "1" ]]; then
      echo "::: install-deps (set SKIP_DEPS=1 to skip)"
      rsync_to "$target" "$DOTFILES_DIR/install-deps.sh" /tmp/install-deps.sh
      ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" -t "$target" 'bash /tmp/install-deps.sh'
    else
      echo "::: install-deps skipped (SKIP_DEPS=1)"
    fi
  fi

  echo "::: ~/.config (source: ${CONFIG_SRC})"
  rsync_to "$target" "$CONFIG_SRC/bbm/config.toml"              ~/.config/bbm/
  rsync_to "$target" "$CONFIG_SRC/btop/"                        ~/.config/btop/
  rsync_to "$target" "$CONFIG_SRC/fastfetch/config.jsonc"       ~/.config/fastfetch/
  rsync_to "$target" "$CONFIG_SRC/fzf/zsh-keybindings.zsh"      ~/.config/fzf/
  rsync_to "$target" "$CONFIG_SRC/gh/config.yml"                ~/.config/gh/
  rsync_to "$target" "$CONFIG_SRC/gh-dash/config.yml"           ~/.config/gh-dash/
  rsync_to "$target" "$CONFIG_SRC/nvim/"                        ~/.config/nvim/
  rsync_to "$target" "$CONFIG_SRC/op/"                          ~/.config/op/
  rsync_to "$target" "$CONFIG_SRC/pikvm/"                       ~/.config/pikvm/
  rsync_to "$target" "$CONFIG_SRC/starship/"                    ~/.config/starship/
  rsync_to "$target" "$CONFIG_SRC/tmux/"                        ~/.config/tmux/
  rsync_to "$target" "$CONFIG_SRC/yazi/"                        ~/.config/yazi/
  # rclone: copy non-secret files only (rclone.conf stays local / 1password)
  rsync_to "$target" "$CONFIG_SRC/rclone/"                      ~/.config/rclone/ 2>/dev/null || true

  echo "::: zsh modules + jay profiles"
  rsync_to "$target" "$DOTFILES_DIR/zsh/platform.zsh"           ~/.config/zsh/
  rsync_to "$target" "$CONFIG_SRC/zsh/"                        ~/.config/zsh/
  rsync_to "$target" "$CONFIG_SRC/jay/profiles/"                ~/.config/jay/profiles/
  rsync_to "$target" "$DOTFILES_DIR/jay/profiles/"              ~/.config/jay/profiles/

  echo "::: rui config (never overwrite existing .env)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  rsync rui/.env.example → ~/.config/rui/ (if .env missing)"
  else
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$target" 'mkdir -p ~/.config/rui'
    if ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$target" '[[ ! -f ~/.config/rui/.env ]]'; then
      if [[ "${CONFIG_SRC_IS_MAC:-0}" == "1" && -f "$MAC_HOME/.config/rui/.env" ]]; then
        rsync_to "$target" "$MAC_HOME/.config/rui/.env" ~/.config/rui/.env
      else
        rsync_to "$target" "$DOTFILES_DIR/rui/.env.example" ~/.config/rui/.env
      fi
    else
      echo "  keep existing ~/.config/rui/.env"
    fi
  fi

  echo "::: ~/.zshrc (linux variant)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  deploy zshrc.linux → ~/.zshrc"
  else
    rsync_to "$target" "$DOTFILES_DIR/zshrc.linux" ~/.zshrc
    # Patch github.zsh pbcopy → clipcopy on the remote copy.
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$target" \
      "sed -i 's/pbcopy/clipcopy/g; s/pbpaste/clippaste/g' ~/.config/zsh/github.zsh 2>/dev/null || true"
  fi

  echo "::: smoke test"
  if [[ "$DRY_RUN" != "1" ]]; then
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$target" \
      'zsh -lic "echo shell=\$SHELL; command -v starship; command -v yazi; command -v rui; fastfetch -l none 2>/dev/null | head -6"' \
      2>&1 | sed 's/^/  /'
  fi
  echo "✓ ${label}"
}

#---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "usage: $0 router [nas ...]"
  echo "hosts: ${!HOSTS[*]}"
  exit 1
fi

for label in "$@"; do
  ip="${HOSTS[$label]:-}"
  [[ -n "$ip" ]] || { echo "unknown host label: $label (known: ${!HOSTS[*]})"; exit 1; }
  deploy_host "$label" "$ip"
done

echo ""
echo "Done. Open a new SSH session (or run: sr) to pick up zsh."
