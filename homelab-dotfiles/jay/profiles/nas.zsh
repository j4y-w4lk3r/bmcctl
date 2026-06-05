#!/usr/bin/env zsh
# jay profile: nas — homelab storage box

jay_profile_setup() {
  local session="$1"
  [[ -n "$session" ]] || return 1

  tmux new-session -d -s "$session" -n yazi -c "$HOME" 'yazi'
  tmux new-window -t "$session" -n btop 'btop'
  tmux new-window -t "$session" -n storage "zsh -i -c 'sudo nvme smart-log /dev/nvme0n1 2>/dev/null | head -20; lsblk; exec zsh'"
  tmux new-window -t "$session" -n tls 'tailscale status; exec zsh'
  tmux new-window -t "$session" -n lazygit 'lazygit'
  tmux new-window -t "$session" -n fastfetch "zsh -i -c 'fastfetch; exec zsh'"
  tmux new-window -t "$session" -n fresh "zsh -i -c 'echo \"nas 💾\"; exec zsh'"
}
