#!/usr/bin/env bash
# Resolve homelab-dotfiles/config/ layout (flat or legacy config/.config/).
resolve_config_src() {
  local dotfiles_dir="$1"
  local mac_home="${2:-$HOME}"
  local base="$dotfiles_dir/config"

  if [[ -d "$base/yazi" || -d "$base/btop" ]]; then
    echo "$base"
  elif [[ -d "$base/.config/yazi" || -d "$base/.config/btop" ]]; then
    echo "$base/.config"
  elif [[ -d "$mac_home/.config/yazi" ]]; then
    echo "$mac_home/.config"
  else
    echo "$base"
  fi
}
