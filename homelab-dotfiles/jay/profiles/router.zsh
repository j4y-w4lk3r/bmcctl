#!/usr/bin/env zsh
# jay profile: router — homelab router box

jay_profile_setup() {
  local session="$1"
  [[ -n "$session" ]] || return 1

  tmux new-session -d -s "$session" -n yazi -c "$HOME" 'yazi'
  tmux new-window -t "$session" -n btop 'btop'
  tmux new-window -t "$session" -n tls 'tailscale status; exec zsh'
  tmux new-window -t "$session" -n rui "zsh -i -c 'command -v rui >/dev/null && rui; exec zsh'"
  tmux new-window -t "$session" -n lazygit 'lazygit'
  tmux new-window -t "$session" -n fastfetch "zsh -i -c 'fastfetch; exec zsh'"
  tmux new-window -t "$session" -n fresh "zsh -i -c 'echo \"router 🛜\"; exec zsh'"
}
